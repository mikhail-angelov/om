import Foundation
import XCTest
@testable import OmVault

final class VaultLinkInspectorTests: XCTestCase {
    func testInspectSeparatesResolvedAndBrokenLinksAndIgnoresCode() throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("Nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("# Target\n".utf8).write(to: vault.appendingPathComponent("Nested/Target.md"))
        try Data(
            """
            [[target|alias]] [[Target.md#Heading]] [[Missing]]
            `[[Inline]]`
            ```
            [[Fenced]]
            ```
                [[Indented]]
            """.utf8
        ).write(to: vault.appendingPathComponent("Source.md"))

        let report = try VaultLinkInspector().inspect(vaultAt: vault)

        XCTAssertEqual(
            report.links,
            [
                VaultLink(
                    from: "Source.md",
                    target: "target",
                    resolved: "Nested/Target.md",
                    alias: "alias"
                ),
                VaultLink(
                    from: "Source.md",
                    target: "Target.md",
                    resolved: "Nested/Target.md",
                    anchor: "Heading"
                ),
            ]
        )
        XCTAssertEqual(
            report.broken,
            [VaultLink(from: "Source.md", target: "Missing")]
        )
    }

    func testInspectRejectsMissingVault() {
        let missingVault = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        XCTAssertThrowsError(try VaultLinkInspector().inspect(vaultAt: missingVault))
    }
}
