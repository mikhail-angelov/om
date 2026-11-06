import Foundation
import OmVault
import XCTest
@testable import OmShell

@MainActor
final class VaultWorkspaceTests: XCTestCase {
    func testOpenVaultBuildsNestedTitleTreeAndPersistsViewPreferences() throws {
        let vault = temporaryVault()
        let nested = vault.appendingPathComponent("Folder/Deep", isDirectory: true)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defer {
            try? FileManager.default.removeItem(at: vault)
            defaults.removePersistentDomain(forName: defaultsSuiteName(defaults))
        }
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "# Zulu Title\n".write(
            to: vault.appendingPathComponent("Folder/Z.md"), atomically: true, encoding: .utf8
        )
        try "# Alpha Title\n".write(
            to: nested.appendingPathComponent("A.md"), atomically: true, encoding: .utf8
        )

        let workspace = VaultWorkspace(logger: RecordingLogger(), preferences: defaults)
        try workspace.openVault(at: vault)

        XCTAssertEqual(workspace.tree.map(\.path), ["Folder"])
        // The file name, not the heading: renaming a note must change what the
        // tree shows, and the heading inside it does not move.
        XCTAssertEqual(workspace.tree[0].children.map(\.title), ["Deep", "Z"])

        workspace.setFolderExpanded("Folder", expanded: true)
        workspace.setSortOrder(VaultSortOrder(field: .name, direction: .descending))

        let reopened = VaultWorkspace(logger: RecordingLogger(), preferences: defaults)
        try reopened.openVault(at: vault)
        XCTAssertTrue(reopened.expandedFolders.contains("Folder"))
        XCTAssertEqual(reopened.sortOrder, VaultSortOrder(field: .name, direction: .descending))
    }

    func testCreateRenameAndOccupiedOperationsEmitExactlyOneEvent() throws {
        let vault = temporaryVault()
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try "# Existing\n".write(
            to: vault.appendingPathComponent("Existing.md"), atomically: true, encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: vault) }
        let logger = RecordingLogger()
        let workspace = VaultWorkspace(logger: logger, preferences: UserDefaults(suiteName: UUID().uuidString)!)
        try workspace.openVault(at: vault)

        XCTAssertEqual(try workspace.createFolder(named: "Ideas"), "Ideas")
        workspace.selectFolder("Ideas")
        let created = try workspace.createNote()
        XCTAssertEqual(created, "Ideas/Untitled.md")
        XCTAssertEqual(try workspace.createNote(), "Ideas/Untitled 2.md")

        try workspace.renameNote(at: created, to: "Renamed")
        XCTAssertTrue(workspace.tabs.contains { $0.path == "Ideas/Renamed.md" })
        XCTAssertThrowsError(try workspace.renameNote(at: "Ideas/Renamed.md", to: "Untitled 2"))

        XCTAssertThrowsError(try workspace.createFolder(named: "Ideas", in: ""))
        XCTAssertEqual(logger.eventNames, [
            "vault.opened",
            "folder.created", "note.created", "note.created", "note.renamed",
            "operation.rejected", "operation.rejected",
        ])
        XCTAssertEqual(workspace.tabs.count, 2)
    }

    func testDeletingClosesTabsAndRestoringReopensTheLastSession() throws {
        let vault = try makeVault([
            "Keep.md": "# Keep\n",
            "Drop/Gone.md": "# Gone\n",
        ])
        defer { try? FileManager.default.removeItem(at: vault) }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let logger = RecordingLogger()
        let workspace = VaultWorkspace(logger: logger, preferences: defaults)
        try workspace.openVault(at: vault)
        try workspace.openNote(at: "Keep.md")
        try workspace.openNoteInNewTab(at: "Drop/Gone.md")
        XCTAssertEqual(workspace.tabs.count, 2)

        // Deleting a folder takes its notes and their tabs with it.
        try workspace.deleteItem(at: "Drop")
        XCTAssertEqual(workspace.tabs.map(\.path), ["Keep.md"])
        XCTAssertFalse(workspace.notes.contains { $0.path == "Drop/Gone.md" })
        XCTAssertTrue(logger.eventNames.contains("folder.deleted"))
        XCTAssertThrowsError(try workspace.deleteItem(at: "Drop"))

        // A fresh workspace over the same preferences comes back where the
        // last one stopped, without being told which vault to open.
        let next = VaultWorkspace(logger: RecordingLogger(), preferences: defaults)
        XCTAssertTrue(next.restoreLastSession())
        XCTAssertEqual(next.vaultURL?.standardizedFileURL, vault.standardizedFileURL)
        XCTAssertEqual(next.tabs.map(\.path), ["Keep.md"])
        XCTAssertEqual(next.activePath, "Keep.md")
    }

    func testSearchFindsNotesByNameAsWellAsByText() throws {
        let vault = try makeVault([
            "Untitled.md": "",
            "Notes/Deep.md": "the word zarkonium lives here\n",
        ])
        defer { try? FileManager.default.removeItem(at: vault) }
        let workspace = VaultWorkspace(
            logger: RecordingLogger(), preferences: UserDefaults(suiteName: UUID().uuidString)!
        )
        try workspace.openVault(at: vault)

        // An empty note is unreachable by content; its name is all there is.
        try workspace.performSearch("title")
        XCTAssertEqual(workspace.searchNameMatches, ["Untitled.md"])
        XCTAssertTrue(workspace.searchResults.isEmpty)

        try workspace.performSearch("ZARKONIUM")
        XCTAssertEqual(workspace.searchResults.map(\.path), ["Notes/Deep.md"])
        XCTAssertTrue(workspace.searchNameMatches.isEmpty)

        try workspace.performSearch("   ")
        XCTAssertTrue(workspace.searchResults.isEmpty)
        XCTAssertTrue(workspace.searchNameMatches.isEmpty)
    }

    func testTabsHistoryAndUnavailableBackAreDeterministic() throws {
        let vault = try makeVault([
            "Source.md": "# Source\n\n[[Target|same]]\n",
            "Target.md": "# Target\n",
        ])
        defer { try? FileManager.default.removeItem(at: vault) }
        let logger = RecordingLogger()
        let workspace = VaultWorkspace(logger: logger, preferences: UserDefaults(suiteName: UUID().uuidString)!)
        try workspace.openVault(at: vault)
        try workspace.openNote(at: "Source.md")

        try workspace.goBack()
        XCTAssertEqual(logger.eventNames, ["vault.opened", "note.opened"])

        let identifier = try XCTUnwrap(linkIdentifier(in: workspace.activeText))
        try workspace.followWikiLink(identifier)
        XCTAssertEqual(workspace.activePath, "Target.md")
        XCTAssertEqual(workspace.tabs.count, 1)

        try workspace.goBack()
        XCTAssertEqual(workspace.activePath, "Source.md")
        try workspace.goForward()
        XCTAssertEqual(workspace.activePath, "Target.md")
        // Opening from the tree gives the note a tab of its own, and the
        // window's history grows whether or not a tab was reused — which is
        // what keeps the arrows usable for someone who never follows a link.
        try workspace.openNote(at: "Source.md")
        XCTAssertEqual(workspace.tabs.count, 2)
        XCTAssertTrue(workspace.canGoBack)
        try workspace.openNote(at: "Target.md")
        XCTAssertEqual(workspace.tabs.count, 2)
        try workspace.goBack()
        XCTAssertEqual(workspace.activePath, "Source.md")

        workspace.closeTab(id: workspace.activeTabID!)
        workspace.closeTab(id: workspace.activeTabID!)
        XCTAssertNil(workspace.activeTabID)
        XCTAssertEqual(logger.eventNames.filter { $0 == "tab.closed" }.count, 2)
        // Two backs: one after following the link, one after opening two notes
        // from the tree. The very first goBack had no history and stayed silent.
        XCTAssertEqual(logger.eventNames.filter { $0 == "history.back" }.count, 2)
        XCTAssertEqual(logger.eventNames.filter { $0 == "history.forward" }.count, 1)
    }

    func testEditingDoesNotReindexAndSaveRefreshesDerivedState() throws {
        let source = """
        ---
        mood: calm
        owner: om
        ---
        # Source

        hello [[Target|a|b]]
        """
        let vault = try makeVault([
            "Source.md": source,
            "Target.md": "# Target\n",
            "Referrer.md": "# Referrer\n\n[[Source]]\n",
        ])
        defer { try? FileManager.default.removeItem(at: vault) }
        let logger = RecordingLogger()
        let workspace = VaultWorkspace(logger: logger, preferences: UserDefaults(suiteName: UUID().uuidString)!)
        try workspace.openVault(at: vault)
        try workspace.openNote(at: "Source.md")
        let revision = workspace.indexRevision

        XCTAssertTrue(workspace.activeText.contains("[[a∣b|om-v1:"))
        XCTAssertEqual(workspace.properties.map(\.name), ["mood", "owner"])
        XCTAssertEqual(workspace.backlinks, ["Referrer.md"])

        try workspace.updateActiveText(workspace.activeText + "\nnew words")
        XCTAssertEqual(workspace.indexRevision, revision)
        try workspace.saveActiveNote()

        XCTAssertEqual(workspace.indexRevision, revision + 1)
        XCTAssertEqual(
            try String(contentsOf: vault.appendingPathComponent("Source.md"), encoding: .utf8),
            source + "\nnew words"
        )
        XCTAssertGreaterThan(workspace.status.words, 2)
        XCTAssertEqual(workspace.status.properties, 2)
        XCTAssertEqual(logger.eventNames.last, "note.saved")

        try workspace.performSearch("new words")
        XCTAssertEqual(workspace.searchResults.map(\.path), ["Source.md"])
        XCTAssertEqual(logger.eventNames.last, "search.performed")

        let externalFolder = vault.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: externalFolder, withIntermediateDirectories: true)
        try workspace.refreshForExternalChanges()
        XCTAssertEqual(workspace.indexRevision, revision + 2)
        XCTAssertTrue(workspace.tree.contains { $0.path == "External" })
    }

    func testMarkupAdapterPreservesAliasesAndDistinctDestinations() throws {
        let source = "[[First|same]] [[Second|same]] [[Target|a|b]]"
        let encoded = EditorMarkupAdapter.encode(source)
        XCTAssertEqual(EditorMarkupAdapter.decode(encoded), source)
        XCTAssertTrue(encoded.contains("[[a∣b|om-v1:"))

        let identifiers = try NSRegularExpression(pattern: #"\|((?:om-v1:)[^\]]+)\]\]"#)
            .matches(
                in: encoded,
                range: NSRange(location: 0, length: (encoded as NSString).length)
            )
            .map { (encoded as NSString).substring(with: $0.range(at: 1)) }
        XCTAssertEqual(Set(identifiers.map(EditorMarkupAdapter.destination(from:))), ["First", "Second", "Target"])
    }

    func testRenderFailureIsLoggedAndWorkspaceRemainsEditable() throws {
        let vault = try makeVault(["Note.md": "# Note\n"])
        defer { try? FileManager.default.removeItem(at: vault) }
        let logger = RecordingLogger()
        let workspace = VaultWorkspace(logger: logger, preferences: UserDefaults(suiteName: UUID().uuidString)!)
        try workspace.openVault(at: vault)
        try workspace.openNote(at: "Note.md")

        workspace.reportRenderFailure(
            exception: "NSRangeException",
            reason: "selection outside text storage",
            stack: ["MarkdownEngine.updateCodeBlockSelection"]
        )
        try workspace.updateActiveText("# Still editing\n")

        XCTAssertEqual(logger.eventNames.last, "render.failed")
        XCTAssertEqual(workspace.activeText, "# Still editing\n")
        XCTAssertEqual(workspace.errorMessage, "selection outside text storage")
    }

    /// A vault is a folder, and the folder's other files are notes too: the
    /// tree lists them, text ones open, and bytes that are not text are
    /// refused rather than shown as mangled characters.
    func testTheVaultShowsEveryFileAndOpensOnlyTheTextOnes() throws {
        let vault = try makeVault([
            "Alpha.md": "# Alpha\n",
            "notes.txt": "a plain list\n",
        ])
        defer { try? FileManager.default.removeItem(at: vault) }
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00]).write(
            to: vault.appendingPathComponent("image.png")
        )
        try Data("# Hidden\n".utf8).write(to: vault.appendingPathComponent(".hidden.md"))

        let workspace = VaultWorkspace(logger: RecordingLogger(), preferences: freshDefaults())
        try workspace.openVault(at: vault)

        XCTAssertEqual(workspace.tree.map(\.path), ["Alpha.md", "image.png", "notes.txt"])
        // Markdown is the vault's native kind, so only its extension is
        // dropped: `notes.txt` and a `notes.md` beside it must read apart.
        XCTAssertEqual(workspace.tree.map(\.title), ["Alpha", "image.png", "notes.txt"])

        try workspace.openNote(at: "notes.txt")
        XCTAssertEqual(workspace.activeText, "a plain list\n")

        XCTAssertThrowsError(try workspace.openNote(at: "image.png")) {
            XCTAssertEqual($0 as? VaultWorkspaceError, .notText("image.png"))
        }
    }

    /// One password covers the whole vault: a sealed note is unreadable until
    /// it is entered, and locking takes it off the screen again.
    func testSealingANoteHidesItUntilTheVaultPasswordIsEntered() throws {
        let vault = try makeVault(["Secret.md": "# Secret\n"])
        defer { try? FileManager.default.removeItem(at: vault) }
        let workspace = VaultWorkspace(logger: RecordingLogger(), preferences: freshDefaults())
        try workspace.openVault(at: vault)

        XCTAssertFalse(workspace.isSecurityConfigured)
        try workspace.openNote(at: "Secret.md")
        try workspace.setPassword("correct horse")
        XCTAssertTrue(workspace.isSecurityConfigured)
        XCTAssertTrue(workspace.isUnlocked)

        try workspace.encryptNote(at: "Secret.md")
        XCTAssertEqual(workspace.tree.map(\.path), ["Secret.omenc"])
        XCTAssertEqual(workspace.tree.map(\.title), ["Secret"])
        // The open tab followed the note through the seal and is still editable.
        XCTAssertEqual(workspace.activePath, "Secret.omenc")
        try workspace.updateActiveText("# Secret\n\nSealed.\n")
        try workspace.saveActiveNote()
        XCTAssertNil(
            try VaultFile.text(at: vault.appendingPathComponent("Secret.omenc")),
            "a sealed note must not read back as text"
        )

        workspace.lock()
        XCTAssertFalse(workspace.isUnlocked)
        XCTAssertTrue(workspace.tabs.isEmpty, "locking must take the decrypted note off the screen")
        XCTAssertThrowsError(try workspace.openNote(at: "Secret.omenc")) {
            XCTAssertEqual($0 as? VaultWorkspaceError, .locked("Secret.omenc"))
        }

        XCTAssertThrowsError(try workspace.unlock(password: "wrong horse"))
        try workspace.unlock(password: "correct horse")
        try workspace.openNote(at: "Secret.omenc")
        XCTAssertEqual(workspace.activeText, "# Secret\n\nSealed.\n")

        try workspace.decryptNote(at: "Secret.omenc")
        XCTAssertEqual(workspace.tree.map(\.path), ["Secret.md"])
        XCTAssertEqual(workspace.activeText, "# Secret\n\nSealed.\n")
    }

    /// Folders lead the tree in every sort order, and the sidebar keeps the
    /// width it was last dragged to across launches.
    func testFoldersLeadTheTreeInEverySortOrderAndTheSidebarWidthSurvives() throws {
        let vault = try makeVault([
            "Apple.md": "# Apple\n",
            "Folder/Inside.md": "# Inside\n",
            "Zebra.md": "# Zebra\n",
        ])
        defer { try? FileManager.default.removeItem(at: vault) }
        let defaults = freshDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let workspace = VaultWorkspace(logger: RecordingLogger(), preferences: defaults)
        try workspace.openVault(at: vault)
        XCTAssertEqual(workspace.tree.map(\.title), ["Folder", "Apple", "Zebra"])

        workspace.setSortOrder(VaultSortOrder(field: .name, direction: .descending))
        XCTAssertEqual(
            workspace.tree.map(\.title), ["Folder", "Zebra", "Apple"],
            "reversing the order must reverse the notes, not sink the folders"
        )

        workspace.setSortOrder(VaultSortOrder(field: .modified, direction: .descending))
        XCTAssertEqual(workspace.tree.first?.kind, .folder)

        XCTAssertEqual(workspace.sidebarWidth, 260, "a fresh vault opens at the default width")
        workspace.setSidebarWidth(420)

        let reopened = VaultWorkspace(logger: RecordingLogger(), preferences: defaults)
        try reopened.openVault(at: vault)
        XCTAssertEqual(reopened.sidebarWidth, 420)
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: UUID().uuidString)!
    }

    private func temporaryVault() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makeVault(_ files: [String: String]) throws -> URL {
        let vault = temporaryVault()
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        for (path, contents) in files {
            let url = vault.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return vault
    }

    private func linkIdentifier(in text: String) -> String? {
        let expression = try! NSRegularExpression(pattern: #"\|((?:om-v1:)[^\]]+)\]\]"#)
        let value = text as NSString
        guard let match = expression.firstMatch(
            in: text, range: NSRange(location: 0, length: value.length)
        ) else { return nil }
        return value.substring(with: match.range(at: 1))
    }

    private func defaultsSuiteName(_ defaults: UserDefaults) -> String {
        defaults.volatileDomainNames.first ?? ""
    }
}

final class RecordingLogger: EventRecording, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [(LogLevel, String, [String: JSONValue])] = []
    var eventNames: [String] { events.map(\.1) }

    func record(level: LogLevel, event: String, fields: [String: JSONValue]) {
        lock.lock()
        events.append((level, event, fields))
        lock.unlock()
    }
}
