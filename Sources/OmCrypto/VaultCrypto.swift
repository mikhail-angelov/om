import CommonCrypto
import CryptoKit
import Foundation
import OmVault

/// The key one password opens a whole vault with. It exists only in memory,
/// for as long as the vault is unlocked.
public struct VaultKey: Sendable {
    fileprivate let material: SymmetricKey
}

public enum VaultCryptoError: LocalizedError, Equatable {
    case emptyPassword
    case wrongPassword
    case alreadyConfigured
    case notConfigured
    case notEncrypted(String)
    case alreadyEncrypted(String)
    case damaged(String)

    public var errorDescription: String? {
        switch self {
        case .emptyPassword: "The vault password cannot be empty."
        case .wrongPassword: "Wrong password."
        case .alreadyConfigured: "This vault already has a password."
        case .notConfigured: "This vault has no password yet."
        case .notEncrypted(let path): "Not an encrypted note: \(path)"
        case .alreadyEncrypted(let path): "Already encrypted: \(path)"
        case .damaged(let path): "The encrypted file is damaged: \(path)"
        }
    }
}

/// A vault's lock: one password for every sealed note in one folder.
///
/// The password is never stored. What lives beside the notes, in
/// `.om/security.json`, is the salt it is stretched with and a verifier the
/// key can open — enough to tell a right password from a wrong one, and enough
/// for the same password to work wherever the folder is carried.
///
/// Notes are sealed with AES-GCM under a key derived by PBKDF2-HMAC-SHA256, so
/// a tampered file fails to open rather than decrypting to something else.
public struct VaultSecurity: Sendable {
    /// OWASP's floor for PBKDF2-HMAC-SHA256, and about a tenth of a second on
    /// the machines this runs on.
    public static let iterations = 600_000
    private static let verifierPlaintext = "om-vault-verifier"
    private static let metadataDirectory = ".om"
    private static let recordFilename = "security.json"

    public init() {}

    // MARK: - The vault password

    public func isConfigured(vaultAt vaultURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: recordURL(for: vaultURL).path)
    }

    /// Gives a vault its password for the first time and returns the key it
    /// derives, so the caller does not have to ask for the password twice.
    @discardableResult
    public func configure(vaultAt vaultURL: URL, password: String) throws -> VaultKey {
        guard !isConfigured(vaultAt: vaultURL) else { throw VaultCryptoError.alreadyConfigured }
        var salt = Data(count: 16)
        salt.withUnsafeMutableBytes { buffer in
            _ = SecRandomCopyBytes(kSecRandomDefault, 16, buffer.baseAddress!)
        }
        let material = try derive(password: password, salt: salt, iterations: Self.iterations)
        let verifier = try AES.GCM.seal(Data(Self.verifierPlaintext.utf8), using: material)
        let record = SecurityRecord(
            version: 1,
            iterations: Self.iterations,
            salt: salt,
            verifier: try sealedData(verifier)
        )
        let url = recordURL(for: vaultURL)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(record).write(to: url, options: .atomic)
        return VaultKey(material: material)
    }

    public func unlock(vaultAt vaultURL: URL, password: String) throws -> VaultKey {
        guard isConfigured(vaultAt: vaultURL) else { throw VaultCryptoError.notConfigured }
        let data = try Data(contentsOf: recordURL(for: vaultURL))
        guard let record = try? JSONDecoder().decode(SecurityRecord.self, from: data) else {
            throw VaultCryptoError.damaged(Self.metadataDirectory + "/" + Self.recordFilename)
        }
        let material = try derive(
            password: password, salt: record.salt, iterations: record.iterations
        )
        guard let box = try? AES.GCM.SealedBox(combined: record.verifier),
              let opened = try? AES.GCM.open(box, using: material),
              opened == Data(Self.verifierPlaintext.utf8) else {
            throw VaultCryptoError.wrongPassword
        }
        return VaultKey(material: material)
    }

    // MARK: - Sealing a note

    /// Seals a file in place: `Note.md` becomes `Note.omenc`, and the original
    /// is removed. The extension it had travels inside the sealed payload, so
    /// unsealing restores the file it was.
    @discardableResult
    public func encrypt(fileAt url: URL, with key: VaultKey) throws -> URL {
        guard !VaultFile.isEncrypted(url.lastPathComponent) else {
            throw VaultCryptoError.alreadyEncrypted(url.lastPathComponent)
        }
        let destination = url.deletingPathExtension()
            .appendingPathExtension(VaultFile.encryptedExtension)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw VaultCryptoError.alreadyEncrypted(destination.lastPathComponent)
        }
        let contents = try Data(contentsOf: url)
        try write(
            contents,
            to: destination,
            fileExtension: url.pathExtension,
            with: key
        )
        try FileManager.default.removeItem(at: url)
        return destination
    }

    /// Unseals a file back into the file it was.
    @discardableResult
    public func decrypt(fileAt url: URL, with key: VaultKey) throws -> URL {
        let note = try sealedNote(at: url)
        let plaintext = try open(note, at: url, with: key)
        let destination = note.fileExtension.isEmpty
            ? url.deletingPathExtension()
            : url.deletingPathExtension().appendingPathExtension(note.fileExtension)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw VaultCryptoError.notEncrypted(destination.lastPathComponent)
        }
        try plaintext.write(to: destination, options: .atomic)
        try FileManager.default.removeItem(at: url)
        return destination
    }

    public func readText(at url: URL, with key: VaultKey) throws -> String {
        let note = try sealedNote(at: url)
        let plaintext = try open(note, at: url, with: key)
        guard let text = String(data: plaintext, encoding: .utf8) else {
            throw VaultCryptoError.damaged(url.lastPathComponent)
        }
        return text
    }

    /// Writes an edit back under the same seal, keeping the extension the note
    /// carried before it was sealed.
    public func writeText(_ text: String, to url: URL, with key: VaultKey) throws {
        let note = try sealedNote(at: url)
        try write(Data(text.utf8), to: url, fileExtension: note.fileExtension, with: key)
    }

    // MARK: - Format

    private struct SecurityRecord: Codable {
        let version: Int
        let iterations: Int
        let salt: Data
        let verifier: Data
    }

    private struct SealedNote: Codable {
        let version: Int
        let fileExtension: String
        let payload: Data

        enum CodingKeys: String, CodingKey {
            case version
            case fileExtension = "extension"
            case payload
        }
    }

    private func write(
        _ plaintext: Data,
        to url: URL,
        fileExtension: String,
        with key: VaultKey
    ) throws {
        let box = try AES.GCM.seal(plaintext, using: key.material)
        let note = SealedNote(
            version: 1,
            fileExtension: fileExtension,
            payload: try sealedData(box)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(note).write(to: url, options: .atomic)
    }

    private func sealedNote(at url: URL) throws -> SealedNote {
        guard VaultFile.isEncrypted(url.lastPathComponent) else {
            throw VaultCryptoError.notEncrypted(url.lastPathComponent)
        }
        let data = try Data(contentsOf: url)
        guard let note = try? JSONDecoder().decode(SealedNote.self, from: data) else {
            throw VaultCryptoError.damaged(url.lastPathComponent)
        }
        return note
    }

    private func open(_ note: SealedNote, at url: URL, with key: VaultKey) throws -> Data {
        guard let box = try? AES.GCM.SealedBox(combined: note.payload) else {
            throw VaultCryptoError.damaged(url.lastPathComponent)
        }
        guard let plaintext = try? AES.GCM.open(box, using: key.material) else {
            throw VaultCryptoError.wrongPassword
        }
        return plaintext
    }

    private func sealedData(_ box: AES.GCM.SealedBox) throws -> Data {
        guard let combined = box.combined else {
            throw VaultCryptoError.damaged("sealed box")
        }
        return combined
    }

    private func recordURL(for vaultURL: URL) -> URL {
        vaultURL.standardizedFileURL
            .appendingPathComponent(Self.metadataDirectory, isDirectory: true)
            .appendingPathComponent(Self.recordFilename)
    }

    private func derive(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        guard !password.isEmpty else { throw VaultCryptoError.emptyPassword }
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBuffer in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                password,
                Data(password.utf8).count,
                saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                UInt32(iterations),
                &derived,
                derived.count
            )
        }
        guard status == kCCSuccess else { throw VaultCryptoError.damaged("key derivation") }
        return SymmetricKey(data: Data(derived))
    }
}
