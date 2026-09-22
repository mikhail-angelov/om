import AppKit
import MarkdownEngine
import OmRenderSupport
import OmShell
import SwiftUI

private func handleRenderException(
    _ name: UnsafePointer<CChar>?,
    _ reason: UnsafePointer<CChar>?,
    _ stack: UnsafePointer<CChar>?
) {
    OmLog.shared.record(level: .error, event: "render.failed", fields: [
        "exception": .string(name.map(String.init(cString:)) ?? "NSException"),
        "reason": .string(reason.map(String.init(cString:)) ?? "Rendering failed"),
        "stack": .strings(stack.map {
            String(cString: $0).components(separatedBy: "\n")
        } ?? []),
    ])
}

@main
struct OmEditorApp: App {
    init() {
        let environment = ProcessInfo.processInfo.environment
        let crashLogger: any EventRecording
        if environment["OM_SELFTEST_CRASH"] != nil,
           let path = environment["OM_SELFTEST_LOG_PATH"],
           let logger = try? JSONEventLogger(logURL: URL(fileURLWithPath: path)) {
            crashLogger = logger
        } else {
            crashLogger = OmLog.shared
        }
        CrashMonitor.install(logger: crashLogger)
        OmInstallRenderExceptionHandler(handleRenderException)
        CrashMonitor.runRequestedSelfTest(environment: environment)
    }

    var body: some Scene {
        WindowGroup("Om Editor") {
            VaultEditorView()
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1_180, height: 760)
    }
}

private struct VaultEditorView: View {
    @StateObject private var model = VaultEditorModel()
    @State private var searchQuery = ""
    @State private var showingNewFolder = false
    @State private var newFolderName = "New Folder"
    @State private var showingRename = false
    @State private var renamePath = ""
    @State private var renameName = ""
    @State private var deletePath: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle(model.vaultURL?.lastPathComponent ?? "Vault")
        } detail: {
            editorColumn
        }
        .toolbar { toolbar }
        .alert(
            "Couldn’t Complete Action",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.clearError() } }
            )
        ) {
            Button("OK") { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: $showingNewFolder) {
            NamePrompt(
                title: "New Folder",
                value: $newFolderName,
                commitTitle: "Create"
            ) {
                model.createFolderFromUI(named: newFolderName)
                showingNewFolder = false
            }
        }
        .sheet(isPresented: $showingRename) {
            NamePrompt(
                title: "Rename Note",
                value: $renameName,
                commitTitle: "Rename"
            ) {
                model.renameNoteFromUI(at: renamePath, to: renameName)
                showingRename = false
            }
        }
        .confirmationDialog(
            "Delete “\(deletePath.map { ($0 as NSString).lastPathComponent } ?? "")”?",
            isPresented: Binding(get: { deletePath != nil }, set: { if !$0 { deletePath = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let deletePath { model.deleteItemFromUI(at: deletePath) }
                deletePath = nil
            }
            Button("Cancel", role: .cancel) { deletePath = nil }
        } message: {
            Text("A folder is deleted with everything inside it. This cannot be undone.")
        }
        .onDisappear { model.flushPendingSave() }
        .task {
            // The vault and the tabs the last session left open. Without this
            // every launch started at the empty state, whatever was open before.
            if model.vaultURL == nil { model.restoreLastSessionFromUI() }
        }
        .task(id: model.vaultURL) {
            while !Task.isCancelled, model.vaultURL != nil {
                try? await Task.sleep(for: .seconds(1))
                model.refreshForExternalChangesFromUI()
            }
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        if model.vaultURL == nil {
            ContentUnavailableView {
                Label("No Vault Open", systemImage: "folder")
            } description: {
                Text("Choose a folder containing Markdown notes.")
            } actions: {
                Button("Open Vault…") { chooseVault() }
            }
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search all notes", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onSubmit { model.searchFromUI(searchQuery) }
                        .onChange(of: searchQuery) { _, query in
                            model.searchFromUI(query)
                        }
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                            model.searchFromUI("")
                        } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                Divider()
                List {
                    if searchQuery.isEmpty {
                        TreeRows(
                            items: model.tree,
                            model: model,
                            rename: beginRename,
                            confirmDelete: beginDelete
                        )
                    } else if model.searchResults.isEmpty, model.searchNameMatches.isEmpty {
                        Text("No matches").foregroundStyle(.secondary)
                    } else {
                        if !model.searchNameMatches.isEmpty {
                            Section("Names") {
                                ForEach(model.searchNameMatches, id: \.self) { path in
                                    Button {
                                        model.selectNoteFromUI(at: path)
                                    } label: {
                                        Label(path, systemImage: "doc.text")
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        ForEach(Array(model.searchResults.enumerated()), id: \.offset) { _, match in
                            Button {
                                model.selectNoteFromUI(at: match.path)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(match.text).lineLimit(1)
                                    Text("\(match.path):\(match.line)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var editorColumn: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            editor
            Divider()
            statusBar
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(model.tabs) { tab in
                    HStack(spacing: 5) {
                        Button(tab.title + (tab.isDirty ? " •" : "")) {
                            model.activateTabFromUI(tab.id)
                        }
                        .buttonStyle(.plain)
                        Button {
                            model.closeTabFromUI(tab.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        tab.id == model.activeTabID ? Color.accentColor.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                }
            }
            .padding(6)
        }
        .frame(height: 40)
    }

    @ViewBuilder
    private var editor: some View {
        if let selectedPath = model.selectedPath {
            NativeTextViewWrapper(
                text: Binding(
                    get: { model.editorText },
                    set: { model.updateEditorTextFromUI($0) }
                ),
                configuration: {
                    var configuration = MarkdownEditorConfiguration(
                        services: MarkdownEditorServices(
                            wikiLinks: VaultWikiLinkResolver(
                                resolvedIdentifiers: model.editorResolvedLinkIdentifiers
                            )
                        )
                    )
                    // Text ran flush against the window edge.
                    configuration.textInsets = TextInsets(horizontal: 20, vertical: 14)
                    // Autocorrect capitalised the first letter of a new word
                    // the moment Return was pressed, which is wrong in a
                    // Markdown note and impossible to undo without noticing.
                    configuration.spellChecking = SpellCheckingPolicy(
                        continuousSpellChecking: true,
                        grammarChecking: false,
                        automaticSpellingCorrection: false
                    )
                    return configuration
                }(),
                documentId: selectedPath,
                onLinkClick: model.followWikiLinkFromUI
            )
            .id(selectedPath)
        } else {
            ContentUnavailableView(
                "No Note Selected",
                systemImage: "doc.text",
                description: Text("Select a note from the vault to edit it.")
            )
        }
    }

    private var statusBar: some View {
        HStack(spacing: 16) {
            Text("Words: \(model.status.words)")
            Text("Characters: \(model.status.characters)")
            Text("Backlinks: \(model.status.backlinks)")
            Text("Properties: \(model.status.properties)")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button("Open Vault", systemImage: "folder") { chooseVault() }
            Button("Back", systemImage: "chevron.left") { model.goBackFromUI() }
                .disabled(!model.canGoBack)
            Button("Forward", systemImage: "chevron.right") { model.goForwardFromUI() }
                .disabled(!model.canGoForward)
            Button("New Note", systemImage: "square.and.pencil") { model.createNoteFromUI() }
                .disabled(model.vaultURL == nil)
            Button("New Folder", systemImage: "folder.badge.plus") {
                newFolderName = "New Folder"
                showingNewFolder = true
            }
            .disabled(model.vaultURL == nil)
            Menu("Sort", systemImage: "arrow.up.arrow.down") {
                sortButton("Name ↑", field: .name, direction: .ascending)
                sortButton("Name ↓", field: .name, direction: .descending)
                sortButton("Modified ↑", field: .modified, direction: .ascending)
                sortButton("Modified ↓", field: .modified, direction: .descending)
            }
            Button("Find", systemImage: "magnifyingglass") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model.vaultURL == nil)
            Button("Save", systemImage: "square.and.arrow.down") { model.saveFromUI() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.selectedPath == nil)
        }
    }

    private func sortButton(
        _ title: String,
        field: VaultSortField,
        direction: VaultSortDirection
    ) -> some View {
        Button(title) {
            model.setSortOrderFromUI(VaultSortOrder(field: field, direction: direction))
        }
    }

    private func beginDelete(_ path: String) {
        deletePath = path
    }

    private func beginRename(path: String, title: String) {
        renamePath = path
        renameName = (path as NSString).lastPathComponent
        renameName = (renameName as NSString).deletingPathExtension
        showingRename = true
    }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            model.openVaultFromUI(at: url)
        }
    }
}

private struct TreeRows: View {
    let items: [VaultTreeItem]
    @ObservedObject var model: VaultEditorModel
    let rename: (String, String) -> Void
    let confirmDelete: (String) -> Void

    var body: some View {
        ForEach(items) { item in
            if item.kind == .folder {
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { model.expandedFolders.contains(item.path) },
                        set: { model.setFolderExpandedFromUI(item.path, expanded: $0) }
                    )
                ) {
                    TreeRows(items: item.children, model: model, rename: rename, confirmDelete: confirmDelete)
                } label: {
                    Label(item.title, systemImage: "folder")
                        .onTapGesture { model.selectFolderFromUI(item.path) }
                        .contextMenu {
                            Button("Delete", role: .destructive) { confirmDelete(item.path) }
                        }
                }
            } else {
                Button {
                    model.selectNoteFromUI(at: item.path)
                } label: {
                    Label(item.title, systemImage: "doc.text")
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Open in New Tab") { model.openInNewTabFromUI(at: item.path) }
                    Button("Rename…") { rename(item.path, item.title) }
                    Divider()
                    Button("Delete", role: .destructive) { confirmDelete(item.path) }
                }
            }
        }
    }
}

private struct NamePrompt: View {
    let title: String
    @Binding var value: String
    let commitTitle: String
    let commit: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            TextField("Name", text: $value)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(commitTitle, action: commit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
