import AppKit
import MarkdownEngine
import OmVault
import SwiftUI

@main
struct OmEditorApp: App {
    var body: some Scene {
        WindowGroup("Om Editor") {
            VaultEditorView()
                .frame(minWidth: 720, minHeight: 480)
        }
    }
}

private struct VaultEditorView: View {
    @StateObject private var model = VaultEditorModel()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle(model.vaultURL?.lastPathComponent ?? "Vault")
                .toolbar {
                    Button("Open Vault", systemImage: "folder") {
                        chooseVault()
                    }
                }
        } detail: {
            editor
        }
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
            List(model.notes, id: \.path, selection: selection) { note in
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title)
                    Text(note.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(note.path)
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let selectedPath = model.selectedPath {
            NativeTextViewWrapper(
                text: Binding(
                    get: { model.source },
                    set: { model.updateSourceFromUI($0) }
                ),
                configuration: editorConfiguration,
                documentId: selectedPath,
                onLinkClick: model.followWikiLinkFromUI
            )
        } else {
            ContentUnavailableView(
                "No Note Selected",
                systemImage: "doc.text",
                description: Text("Select a note from the vault to edit it.")
            )
        }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { model.selectedPath },
            set: { model.selectNoteFromUI(at: $0) }
        )
    }

    private var editorConfiguration: MarkdownEditorConfiguration {
        MarkdownEditorConfiguration(
            services: MarkdownEditorServices(
                wikiLinks: VaultWikiLinkResolver(
                    resolvedIdentifiers: model.resolvedLinkIdentifiers
                )
            )
        )
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
