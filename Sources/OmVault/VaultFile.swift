import Foundation

/// What a vault file is made of. A vault is a folder, and a folder holds more
/// than Markdown, so everything that reads a file's contents has to answer two
/// questions first: is this text at all, and is it sealed.
public enum VaultFile {
    /// The suffix a sealed note carries. The engine never looks inside one — it
    /// only knows not to read it as text; `OmCrypto` owns the format.
    public static let encryptedExtension = "omenc"

    public static func isEncrypted(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == encryptedExtension
    }

    /// Entries a vault does not own: dotfiles, `.DS_Store`, and the `.om`
    /// directory that holds the vault's own metadata.
    public static func isHidden(_ name: String) -> Bool {
        name.hasPrefix(".")
    }

    /// The file's contents when it is readable text, and `nil` when it is
    /// sealed or binary. Titles, search and link parsing all stop here.
    public static func text(at url: URL) throws -> String? {
        guard !isEncrypted(url.lastPathComponent) else { return nil }
        let data = try Data(contentsOf: url)
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
}
