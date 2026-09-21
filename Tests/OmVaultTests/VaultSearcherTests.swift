import Foundation
import XCTest
@testable import OmVault

final class VaultSearcherTests: XCTestCase {
    func testSearchReturnsSortedCaseInsensitiveSubstringMatchesFromMarkdownNotes() throws {
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
        try Data("needle ignored\n".utf8).write(
            to: vault.appendingPathComponent("notes.txt")
        )

        let report = try VaultSearcher().search(vaultAt: vault, query: "NEED")

        XCTAssertEqual(
            report,
            VaultSearchReport(
                matches: [
                    VaultSearchMatch(path: "Nested/A Note.md", line: 1, text: "A Needle nested"),
                    VaultSearchMatch(path: "Zeta.md", line: 1, text: "First needle"),
                    VaultSearchMatch(path: "Zeta.md", line: 3, text: "Another NEEDLE"),
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
