import Foundation
import OmShell
import OmVault
import SwiftUI

@MainActor
final class VaultEditorModel: ObservableObject {
    let workspace: VaultWorkspace
    @Published private var adapterError: String?
    private var autosave: Task<Void, Never>?

    init(workspace: VaultWorkspace? = nil) {
        self.workspace = workspace ?? VaultWorkspace(linkInspector: VaultLinkInspector())
    }

    var vaultURL: URL? { workspace.vaultURL }
    var notes: [VaultNote] { workspace.notes }
    var tree: [VaultTreeItem] { workspace.tree }
    var tabs: [VaultTab] { workspace.tabs }
    var activeTabID: UUID? { workspace.activeTabID }
    var selectedPath: String? { workspace.activePath }
    var source: String { EditorMarkupAdapter.decode(workspace.activeText) }
    var editorText: String { workspace.activeText }
    var resolvedLinkIdentifiers: Set<String> { workspace.resolvedLinkIdentifiers }
    var editorResolvedLinkIdentifiers: Set<String> { workspace.editorResolvedLinkIdentifiers }
    var expandedFolders: Set<String> { workspace.expandedFolders }
    var sortOrder: VaultSortOrder { workspace.sortOrder }
    var sidebarWidth: Double { workspace.sidebarWidth }
    var searchResults: [VaultSearchMatch] { workspace.searchResults }
    var searchNameMatches: [String] { workspace.searchNameMatches }
    var backlinks: [String] { workspace.backlinks }
    var properties: [NoteProperty] { workspace.properties }
    var status: NoteStatus { workspace.status }
    var canGoBack: Bool { workspace.canGoBack }
    var canGoForward: Bool { workspace.canGoForward }
    var isSecurityConfigured: Bool { workspace.isSecurityConfigured }
    var isUnlocked: Bool { workspace.isUnlocked }
    func isEncrypted(_ path: String) -> Bool { workspace.isEncrypted(path) }
    var errorMessage: String? { adapterError ?? workspace.errorMessage }

    func openVault(at url: URL) throws {
        try changed { try workspace.openVault(at: url) }
    }

    func selectNote(at path: String?) throws {
        try changed {
            if let path { try workspace.openNote(at: path) }
            else { workspace.resetTabs() }
        }
    }

    func updateSource(_ newSource: String) throws {
        try changed {
            try workspace.updateActiveText(EditorMarkupAdapter.encode(newSource))
            try workspace.saveActiveNote()
        }
    }

    func followWikiLink(_ identifier: String) throws {
        try changed { try workspace.followWikiLink(identifier) }
    }

    func openVaultFromUI(at url: URL) { captureError { try workspace.openVault(at: url) } }
    func restoreLastSessionFromUI() { changed { _ = workspace.restoreLastSession() } }
    func selectNoteFromUI(at path: String?) {
        guard let path else { return }
        flushPendingSave()
        captureError { try workspace.openNote(at: path) }
    }
    func openInNewTabFromUI(at path: String) {
        captureError { try workspace.openNoteInNewTab(at: path) }
    }
    func deleteItemFromUI(at path: String) { captureError { try workspace.deleteItem(at: path) } }
    /// Typing changes the buffer and schedules a write. Without this the only
    /// way to keep an edit was to remember ⌘S, and closing the window lost it.
    func updateEditorTextFromUI(_ text: String) {
        captureError { try workspace.updateActiveText(text) }
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        autosave?.cancel()
        autosave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self else { return }
            self.saveFromUI()
        }
    }

    /// Writes anything still pending, for the moments a timer would miss:
    /// switching notes, closing a tab, quitting.
    func flushPendingSave() {
        autosave?.cancel()
        autosave = nil
        if workspace.activeTab?.isDirty == true { saveFromUI() }
    }
    func followWikiLinkFromUI(_ identifier: String) { captureError { try workspace.followWikiLink(identifier) } }
    func saveFromUI() { captureError { try workspace.saveActiveNote() } }
    func setPasswordFromUI(_ password: String) { changed { captureError { try workspace.setPassword(password) } } }
    func unlockFromUI(with password: String) { changed { captureError { try workspace.unlock(password: password) } } }
    func lockFromUI() {
        flushPendingSave()
        changed { workspace.lock() }
    }
    func encryptNoteFromUI(at path: String) {
        flushPendingSave()
        captureError { try workspace.encryptNote(at: path) }
    }
    func decryptNoteFromUI(at path: String) {
        flushPendingSave()
        captureError { try workspace.decryptNote(at: path) }
    }
    func createNoteFromUI() { captureError { try workspace.createNote() } }
    func createFolderFromUI(named name: String) { captureError { try workspace.createFolder(named: name) } }
    func renameNoteFromUI(at path: String, to name: String) {
        captureError { try workspace.renameNote(at: path, to: name) }
    }
    func activateTabFromUI(_ id: UUID) {
        flushPendingSave()
        changed { workspace.activateTab(id: id) }
    }
    func closeTabFromUI(_ id: UUID) {
        flushPendingSave()
        changed { workspace.closeTab(id: id) }
    }
    func goBackFromUI() { captureError { try workspace.goBack() } }
    func goForwardFromUI() { captureError { try workspace.goForward() } }
    func searchFromUI(_ query: String) { captureError { try workspace.performSearch(query) } }
    func selectFolderFromUI(_ path: String) { changed { workspace.selectFolder(path) } }
    func setFolderExpandedFromUI(_ path: String, expanded: Bool) {
        changed { workspace.setFolderExpanded(path, expanded: expanded) }
    }
    func setSortOrderFromUI(_ order: VaultSortOrder) { changed { workspace.setSortOrder(order) } }
    /// Not routed through `changed`: remembering the width must not redraw the
    /// column the user is still dragging.
    func rememberSidebarWidthFromUI(_ width: Double) { workspace.setSidebarWidth(width) }
    func refreshForExternalChangesFromUI() { captureError { try workspace.refreshForExternalChanges() } }

    func clearError() {
        changed {
            adapterError = nil
            workspace.clearError()
        }
    }

    private func captureError(_ operation: () throws -> Void) {
        objectWillChange.send()
        do {
            try operation()
            adapterError = nil
        } catch {
            adapterError = error.localizedDescription
        }
    }

    @discardableResult
    private func changed<T>(_ operation: () throws -> T) rethrows -> T {
        objectWillChange.send()
        return try operation()
    }
}
