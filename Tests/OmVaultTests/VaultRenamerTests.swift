import Foundation
import XCTest
@testable import OmVault

final class VaultRenamerTests: XCTestCase {
    func testRenameMovesNoteAndUpdatesOnlyResolvedLinks() throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try Data("Self: [[Target|alias]]\n".utf8).write(
            to: vault.appendingPathComponent("Target.md")
        )
        try Data("Real: [[target.md#Heading]] `[[Target]]` [[Missing]]\n".utf8).write(
            to: vault.appendingPathComponent("Source.md")
        )

        let report = try VaultRenamer().rename(
            vaultAt: vault,
            from: "TARGET",
            to: "Renamed"
        )

        XCTAssertEqual(
            report,
            VaultRenameReport(
                renamed: VaultRenamedNote(from: "Target.md", to: "Renamed.md"),
                updated: [
                    VaultUpdatedFile(path: "Renamed.md", links: 1),
                    VaultUpdatedFile(path: "Source.md", links: 1),
                ],
                skipped: []
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.appendingPathComponent("Target.md").path))
        XCTAssertEqual(
            try String(contentsOf: vault.appendingPathComponent("Renamed.md"), encoding: .utf8),
            "Self: [[Renamed|alias]]\n"
        )
        XCTAssertEqual(
            try String(contentsOf: vault.appendingPathComponent("Source.md"), encoding: .utf8),
            "Real: [[Renamed.md#Heading]] `[[Target]]` [[Missing]]\n"
        )
    }

    func testRenameRejectsOccupiedDestinationWithoutChangingFiles() throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let source = Data("[[Target]]\n".utf8)
        let occupied = Data("# Occupied\n".utf8)
        try source.write(to: vault.appendingPathComponent("Target.md"))
        try occupied.write(to: vault.appendingPathComponent("Occupied.md"))

        XCTAssertThrowsError(
            try VaultRenamer().rename(vaultAt: vault, from: "Target", to: "Occupied")
        ) { error in
            XCTAssertEqual(error as? VaultRenameError, .destinationOccupied("Occupied"))
        }
        XCTAssertEqual(try Data(contentsOf: vault.appendingPathComponent("Target.md")), source)
        XCTAssertEqual(try Data(contentsOf: vault.appendingPathComponent("Occupied.md")), occupied)
    }
}
