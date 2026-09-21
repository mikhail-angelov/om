import Foundation
import XCTest
@testable import OmEditor

@MainActor
final class VaultEditorModelTests: XCTestCase {
    func testOpenSelectEditAndReopenNestedNote() throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = vault.appendingPathComponent("Nested", isDirectory: true)
        let note = nested.appendingPathComponent("A Note.md")
        defer { try? FileManager.default.removeItem(at: vault) }

        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true
        )
        try Data("# Original\n".utf8).write(to: note)

        let model = VaultEditorModel()
        try model.openVault(at: vault)

        XCTAssertEqual(model.notes.map(\.path), ["Nested/A Note.md"])

        try model.selectNote(at: "Nested/A Note.md")
        XCTAssertEqual(model.source, "# Original\n")

        try model.updateSource("# Edited\n\nLive preview text.\n")
        try model.selectNote(at: nil)
        try model.selectNote(at: "Nested/A Note.md")

        XCTAssertEqual(model.source, "# Edited\n\nLive preview text.\n")
        XCTAssertEqual(
            try String(contentsOf: note, encoding: .utf8),
            "# Edited\n\nLive preview text.\n"
        )
    }
}
