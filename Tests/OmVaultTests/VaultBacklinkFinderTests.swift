import Foundation
import XCTest
@testable import OmVault

final class VaultBacklinkFinderTests: XCTestCase {
    func testFindReturnsEachSortedReferrerUsingLinkResolutionRules() throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try Data("[[Target]] [[target.md]]\n".utf8).write(
            to: vault.appendingPathComponent("Beta.md")
        )
        try Data("`[[Target]]`\n".utf8).write(
            to: vault.appendingPathComponent("CodeOnly.md")
        )
        try Data("[[TARGET]]\n".utf8).write(
            to: vault.appendingPathComponent("Alpha.md")
        )
        try Data("# Target\n".utf8).write(
            to: vault.appendingPathComponent("Target.md")
        )

        let report = try VaultBacklinkFinder().find(
            vaultAt: vault,
            noteName: "TARGET.md"
        )

        XCTAssertEqual(report, VaultBacklinksReport(backlinks: ["Alpha.md", "Beta.md"]))
    }
}
