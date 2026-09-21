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
        try Data("ignored\n".utf8).write(to: vault.appendingPathComponent("notes.txt"))

        let inventory = try VaultIndexer().index(vaultAt: vault)

        XCTAssertEqual(
            inventory.notes,
            [
                VaultNote(path: "Fallback.md", name: "Fallback", title: "Fallback"),
                VaultNote(path: "Nested/Note.md", name: "Note", title: "Note"),
            ]
        )
    }

    func testIndexRejectsMissingVault() {
        let missingVault = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        XCTAssertThrowsError(try VaultIndexer().index(vaultAt: missingVault))
    }
}
