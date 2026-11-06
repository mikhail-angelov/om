import Foundation
import XCTest
@testable import OmVault

final class VaultIndexerTests: XCTestCase {
    func testIndexReturnsDeterministicInventoryThroughPublicAPI() throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("Nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("## Not a title\n".utf8).write(to: vault.appendingPathComponent("Fallback.md"))
        try Data("## Not a title\n".utf8).write(to: vault.appendingPathComponent("Nested/Note.md"))
        try Data("plain text\n".utf8).write(to: vault.appendingPathComponent("notes.txt"))
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00]).write(to: vault.appendingPathComponent("image.png"))
        try Data("# Hidden\n".utf8).write(to: vault.appendingPathComponent(".hidden.md"))

        let inventory = try VaultIndexer().index(vaultAt: vault)

        // Every file in the folder, whatever it is; only dotfiles stay out.
        XCTAssertEqual(
            inventory.notes,
            [
                VaultNote(path: "Fallback.md", name: "Fallback", title: "Fallback"),
                VaultNote(path: "Nested/Note.md", name: "Note", title: "Note"),
                VaultNote(path: "image.png", name: "image", title: "image"),
                VaultNote(path: "notes.txt", name: "notes", title: "notes"),
            ]
        )
    }

    func testIndexRejectsMissingVault() {
        let missingVault = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        XCTAssertThrowsError(try VaultIndexer().index(vaultAt: missingVault))
    }
}
