import Foundation
import XCTest
@testable import OmVault

final class VaultSearcherTests: XCTestCase {
    func testSearchReturnsSortedCaseInsensitiveSubstringMatchesFromEveryTextFile() throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("Nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("First needle\nNo match\nAnother NEEDLE\n".utf8).write(
            to: vault.appendingPathComponent("Zeta.md")
        )
        try Data("A Needle nested\n".utf8).write(
            to: vault.appendingPathComponent("Nested/A Note.md")
        )
        try Data("needle in plain text\n".utf8).write(
            to: vault.appendingPathComponent("notes.txt")
        )
        // Bytes that are not text: in the index, never in the results.
        try (Data([0x89, 0x50, 0x4E, 0x47, 0x00]) + Data("needle\n".utf8)).write(
            to: vault.appendingPathComponent("image.png")
        )

        let report = try VaultSearcher().search(vaultAt: vault, query: "NEED")

        XCTAssertEqual(
            report,
            VaultSearchReport(
                matches: [
                    VaultSearchMatch(path: "Nested/A Note.md", line: 1, text: "A Needle nested"),
                    VaultSearchMatch(path: "Zeta.md", line: 1, text: "First needle"),
                    VaultSearchMatch(path: "Zeta.md", line: 3, text: "Another NEEDLE"),
                    VaultSearchMatch(path: "notes.txt", line: 1, text: "needle in plain text"),
                ]
            )
        )
        XCTAssertEqual(
            try VaultSearcher().search(vaultAt: vault, query: "absent"),
            VaultSearchReport(matches: [])
        )
    }

    func testSearchRejectsMissingVault() {
        let missingVault = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        XCTAssertThrowsError(
            try VaultSearcher().search(vaultAt: missingVault, query: "needle")
        )
    }
}
