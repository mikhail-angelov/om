import Foundation
import OmVault
import XCTest
@testable import OmCrypto

final class VaultCryptoTests: XCTestCase {
    private let security = VaultSecurity()

    func testOneVaultPasswordSealsAndOpensANoteAndKeepsItsKind() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let note = vault.appendingPathComponent("Secret.md")
        try "# Secret\n\nThe recipe.\n".write(to: note, atomically: true, encoding: .utf8)

        let key = try security.configure(vaultAt: vault, password: "correct horse")
        let sealed = try security.encrypt(fileAt: note, with: key)

        XCTAssertEqual(sealed.lastPathComponent, "Secret.omenc")
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.path))
        // Nothing readable is left in the file itself.
        let bytes = try Data(contentsOf: sealed)
        XCTAssertNil(bytes.range(of: Data("The recipe.".utf8)))

        // A second session derives the same key from the same password.
        let reopened = try security.unlock(vaultAt: vault, password: "correct horse")
        XCTAssertEqual(
            try security.readText(at: sealed, with: reopened),
            "# Secret\n\nThe recipe.\n"
        )

        try security.writeText("# Secret\n\nA new recipe.\n", to: sealed, with: reopened)
        let plain = try security.decrypt(fileAt: sealed, with: reopened)
        XCTAssertEqual(plain.lastPathComponent, "Secret.md", "the extension must survive the seal")
        XCTAssertEqual(
            try String(contentsOf: plain, encoding: .utf8),
            "# Secret\n\nA new recipe.\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: sealed.path))
    }

    func testTheWrongPasswordOpensNothingAndTheRightOneIsNeverStored() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let note = vault.appendingPathComponent("Secret.md")
        try "sealed\n".write(to: note, atomically: true, encoding: .utf8)

        let key = try security.configure(vaultAt: vault, password: "correct horse")
        let sealed = try security.encrypt(fileAt: note, with: key)

        XCTAssertThrowsError(try security.unlock(vaultAt: vault, password: "wrong horse")) {
            XCTAssertEqual($0 as? VaultCryptoError, .wrongPassword)
        }
        XCTAssertThrowsError(try security.configure(vaultAt: vault, password: "another")) {
            XCTAssertEqual($0 as? VaultCryptoError, .alreadyConfigured)
        }
        XCTAssertThrowsError(try security.configure(vaultAt: try makeVault(), password: "")) {
            XCTAssertEqual($0 as? VaultCryptoError, .emptyPassword)
        }

        let record = try String(
            contentsOf: vault.appendingPathComponent(".om/security.json"), encoding: .utf8
        )
        XCTAssertFalse(
            record.contains("correct horse"),
            "the password itself must never be written to disk"
        )
        XCTAssertTrue(VaultSecurity().isConfigured(vaultAt: vault))

        // A vault holding only a sealed note still indexes it, and the engine
        // never tries to read its bytes as text.
        let inventory = try VaultIndexer().index(vaultAt: vault)
        XCTAssertEqual(inventory.notes.map(\.path), ["Secret.omenc"])
        XCTAssertNil(try VaultFile.text(at: sealed))
        XCTAssertEqual(try VaultSearcher().search(vaultAt: vault, query: "sealed").matches, [])
    }

    func testATamperedNoteFailsToOpenRatherThanDecryptingToSomethingElse() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let note = vault.appendingPathComponent("Secret.md")
        try "sealed\n".write(to: note, atomically: true, encoding: .utf8)
        let key = try security.configure(vaultAt: vault, password: "correct horse")
        let sealed = try security.encrypt(fileAt: note, with: key)

        var contents = try String(contentsOf: sealed, encoding: .utf8)
        // Flip one base64 character of the ciphertext.
        let payloadMarker = "\"payload\":\""
        let start = contents.range(of: payloadMarker)!.upperBound
        let victim = contents.index(start, offsetBy: 4)
        contents.replaceSubrange(victim...victim, with: contents[victim] == "A" ? "B" : "A")
        try contents.write(to: sealed, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try security.readText(at: sealed, with: key)) {
            XCTAssertEqual($0 as? VaultCryptoError, .wrongPassword)
        }
    }

    private func makeVault() throws -> URL {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        return vault
    }
}
