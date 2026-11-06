import AppKit
import MarkdownEngine
import OmVault
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
        .commands {
            // A menu of its own: hooking these into Edit's undo/redo group is
            // one of the SwiftUI Edit-menu customizations that silently kills
            // the standard Undo/Redo items — ⌘Z stopped working when tried.
            CommandMenu("Line") {
                Button("Move Line Up") { EditorLineCommands.moveFocusedLine(up: true) }
                    .keyboardShortcut(.upArrow, modifiers: .option)
                Button("Move Line Down") { EditorLineCommands.moveFocusedLine(up: false) }
                    .keyboardShortcut(.downArrow, modifiers: .option)
                Divider()
                Button("Duplicate Line Above") { EditorLineCommands.duplicateFocusedLine(below: false) }
                    .keyboardShortcut(.upArrow, modifiers: [.option, .shift])
                Button("Duplicate Line Below") { EditorLineCommands.duplicateFocusedLine(below: true) }
                    .keyboardShortcut(.downArrow, modifiers: [.option, .shift])
            }
        }
    }
}

/// The engine searches its own displayed text and answers with a count, which
/// is why the host does not compute ranges itself: displayed text is shorter
/// than the source wherever a wiki link is rendered, and host-computed ranges
/// would highlight the wrong characters.
private enum FindBus {
    static let query = Notification.Name("om.find.query")
    static let results = Notification.Name("om.find.results")
    static let clear = Notification.Name("om.find.clear")
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
    @State private var noteQuery = ""
    @State private var noteMatchIndex = 0
    @State private var noteMatchCount = 0
    @State private var showingFind = false
    @FocusState private var findFocused: Bool
    @State private var pendingFind: String?
    @State private var passwordRequest: PasswordRequest?
    /// The note waiting on the password sheet: sealing or opening one is what
    /// usually sends a user to the lock in the first place.
    @State private var pendingSeal: PendingSeal?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle(model.vaultURL?.lastPathComponent ?? "Vault")
                .navigationSplitViewColumnWidth(
                    min: 180, ideal: model.sidebarWidth, max: 560
                )
                .background(
                    GeometryReader { proxy in
                        Color.clear.onChange(of: proxy.size.width) { _, width in
                            model.rememberSidebarWidthFromUI(width)
                        }
                    }
                )
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
        .sheet(item: $passwordRequest) { request in
            PasswordPrompt(
                title: request.title,
                message: request.message,
                requiresConfirmation: request == .create
            ) { password in
                if request == .create {
                    model.setPasswordFromUI(password)
                } else {
                    model.unlockFromUI(with: password)
                }
                passwordRequest = nil
                completePendingSeal()
            } cancel: {
                passwordRequest = nil
                pendingSeal = nil
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
        .onReceive(NotificationCenter.default.publisher(for: FindBus.results)) { note in
            noteMatchCount = note.userInfo?["count"] as? Int ?? 0
            if noteMatchCount == 0 { noteMatchIndex = 0 }
        }
        .onChange(of: model.selectedPath) { _, _ in
            // A note opened from the global search carries the query with it:
            // the engine can only be asked once its view exists, so the request
            // waits here for the document to actually change.
            guard let query = pendingFind else { return }
            pendingFind = nil
            noteQuery = query
            showingFind = true
            runFind(query, index: 0)
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
                Text("Choose a folder. Om shows every file in it.")
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
                    sortMenu
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
                            confirmDelete: beginDelete,
                            seal: beginSeal
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
                                pendingFind = searchQuery
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
            if showingFind { findBar; Divider() }
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

    private var findBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in note", text: $noteQuery)
                .textFieldStyle(.plain)
                .focused($findFocused)
                .onSubmit { stepFind(by: 1) }
                .onChange(of: noteQuery) { _, query in runFind(query, index: 0) }
            Text(noteMatchCount == 0 ? (noteQuery.isEmpty ? "" : "none")
                 : "\(noteMatchIndex + 1) of \(noteMatchCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button { stepFind(by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain).disabled(noteMatchCount == 0)
            Button { stepFind(by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain)
                .keyboardShortcut("g", modifiers: .command)
                .disabled(noteMatchCount == 0)
            Button { closeFind() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func runFind(_ query: String, index: Int) {
        guard !query.isEmpty else {
            noteMatchCount = 0
            NotificationCenter.default.post(name: FindBus.clear, object: nil)
            return
        }
        noteMatchIndex = index
        NotificationCenter.default.post(
            name: FindBus.query, object: nil,
            userInfo: ["query": query, "currentIndex": index]
        )
    }

    private func stepFind(by delta: Int) {
        guard noteMatchCount > 0 else { return }
        let next = (noteMatchIndex + delta + noteMatchCount) % noteMatchCount
        runFind(noteQuery, index: next)
    }

    private func closeFind() {
        showingFind = false
        noteQuery = ""
        noteMatchCount = 0
        NotificationCenter.default.post(name: FindBus.clear, object: nil)
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
                            ),
                            bus: MarkdownEditorBus(
                                findClearHighlights: FindBus.clear,
                                findQuery: FindBus.query,
                                findResults: FindBus.results
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
        // The lock sits on its own at the leading edge. In the trailing group
        // it was the tenth item and the first one macOS folded away into the
        // overflow menu, which made the feature look absent.
        ToolbarItem(placement: .navigation) { lockButton }
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
            Button("Find in Note", systemImage: "text.magnifyingglass") {
                showingFind = true
                findFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(model.selectedPath == nil)
            Button("Search Vault", systemImage: "magnifyingglass") { searchFocused = true }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(model.vaultURL == nil)
            Button("Save", systemImage: "square.and.arrow.down") { model.saveFromUI() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.selectedPath == nil)
        }
    }

    /// One control for the vault's one password: it sets it, opens it, or
    /// closes it again, depending on where the vault stands.
    @ViewBuilder
    private var lockButton: some View {
        if !model.isSecurityConfigured {
            Button("Set Vault Password", systemImage: "key.fill") {
                pendingSeal = nil
                passwordRequest = .create
            }
            .disabled(model.vaultURL == nil)
        } else if model.isUnlocked {
            Button("Lock Vault", systemImage: "lock.open") { model.lockFromUI() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        } else {
            Button("Unlock Vault", systemImage: "lock.fill") {
                pendingSeal = nil
                passwordRequest = .unlock
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }

    /// Sorting belongs to the list it sorts, so the control sits in the
    /// sidebar's header rather than in the window toolbar across the way.
    private var sortMenu: some View {
        Menu {
            sortButton("Name ↑", field: .name, direction: .ascending)
            sortButton("Name ↓", field: .name, direction: .descending)
            sortButton("Modified ↑", field: .modified, direction: .ascending)
            sortButton("Modified ↓", field: .modified, direction: .descending)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort the vault")
        .disabled(model.vaultURL == nil)
    }

    private func sortButton(
        _ title: String,
        field: VaultSortField,
        direction: VaultSortDirection
    ) -> some View {
        let order = VaultSortOrder(field: field, direction: direction)
        return Button {
            model.setSortOrderFromUI(order)
        } label: {
            if model.sortOrder == order {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func beginDelete(_ path: String) {
        deletePath = path
    }

    /// Sealing and unsealing both need the vault open. Whichever step is
    /// missing — a password that was never set, or one that was not entered
    /// this session — is asked for first, and the note follows.
    private func beginSeal(_ seal: PendingSeal) {
        guard model.isSecurityConfigured else {
            pendingSeal = seal
            passwordRequest = .create
            return
        }
        guard model.isUnlocked else {
            pendingSeal = seal
            passwordRequest = .unlock
            return
        }
        pendingSeal = seal
        completePendingSeal()
    }

    private func completePendingSeal() {
        guard let seal = pendingSeal, model.isUnlocked else { return }
        pendingSeal = nil
        switch seal.direction {
        case .encrypt: model.encryptNoteFromUI(at: seal.path)
        case .decrypt: model.decryptNoteFromUI(at: seal.path)
        }
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

/// Which way a note is about to cross the vault's seal.
private struct PendingSeal {
    enum Direction { case encrypt, decrypt }
    let path: String
    let direction: Direction
}

private enum PasswordRequest: Identifiable {
    case create
    case unlock

    var id: Int { self == .create ? 0 : 1 }

    var title: String {
        self == .create ? "Set Vault Password" : "Unlock Vault"
    }

    var message: String {
        self == .create
            ? "One password covers every encrypted note in this vault. It is not stored anywhere and cannot be recovered."
            : "Enter the vault password to open its encrypted notes."
    }
}

private struct PasswordPrompt: View {
    let title: String
    let message: String
    let requiresConfirmation: Bool
    let commit: (String) -> Void
    let cancel: () -> Void
    @State private var password = ""
    @State private var confirmation = ""

    private var isValid: Bool {
        !password.isEmpty && (!requiresConfirmation || password == confirmation)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary)
            SecureField("Password", text: $password)
                .onSubmit { if isValid { commit(password) } }
            if requiresConfirmation {
                SecureField("Repeat password", text: $confirmation)
                    .onSubmit { if isValid { commit(password) } }
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(title, action: { commit(password) })
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

private struct TreeRows: View {
    let items: [VaultTreeItem]
    @ObservedObject var model: VaultEditorModel
    let rename: (String, String) -> Void
    let confirmDelete: (String) -> Void
    let seal: (PendingSeal) -> Void

    var body: some View {
        ForEach(items) { item in
            if item.kind == .folder {
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { model.expandedFolders.contains(item.path) },
                        set: { model.setFolderExpandedFromUI(item.path, expanded: $0) }
                    )
                ) {
                    TreeRows(
                        items: item.children, model: model, rename: rename,
                        confirmDelete: confirmDelete, seal: seal
                    )
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
                    Label(
                        item.title,
                        systemImage: model.isEncrypted(item.path) ? "lock.doc" : "doc.text"
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Open in New Tab") { model.openInNewTabFromUI(at: item.path) }
                    Button("Rename…") { rename(item.path, item.title) }
                    if model.isEncrypted(item.path) {
                        Button("Decrypt…") { seal(PendingSeal(path: item.path, direction: .decrypt)) }
                    } else {
                        Button("Encrypt…") { seal(PendingSeal(path: item.path, direction: .encrypt)) }
                    }
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
