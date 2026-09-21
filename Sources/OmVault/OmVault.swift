import Foundation

public struct VaultNote: Codable, Equatable, Sendable {
    public let path: String
    public let name: String
    public let title: String

    public init(path: String, name: String, title: String) {
        self.path = path
        self.name = name
        self.title = title
    }
}

public struct VaultInventory: Codable, Equatable, Sendable {
    public let notes: [VaultNote]

    public init(notes: [VaultNote]) {
        self.notes = notes
    }
}

public enum VaultIndexError: LocalizedError, Equatable {
    case invalidVault(String)

    public var errorDescription: String? {
        switch self {
        case .invalidVault(let path):
            return "Invalid or unreadable vault: \(path)"
        }
    }
}

public struct VaultIndexer: Sendable {
    public init() {}

    public func index(vaultAt vaultURL: URL) throws -> VaultInventory {
        let fileManager = FileManager.default
        let root = vaultURL.standardizedFileURL
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isReadableFile(atPath: root.path) else {
            throw VaultIndexError.invalidVault(root.path)
        }

        let files = try markdownFiles(in: root, relativeTo: "", using: fileManager)
        let notes = try files.map { file in
            let fileURL = file.url
            let relativePath = file.path
            let name = (relativePath as NSString).deletingPathExtension
            let contents = try String(contentsOf: fileURL, encoding: .utf8)

            return VaultNote(
                path: relativePath,
                name: name,
                title: firstLevelOneHeading(in: contents) ?? name
            )
        }

        return VaultInventory(notes: notes.sorted { $0.path < $1.path })
    }

    private func markdownFiles(
        in directory: URL,
        relativeTo relativeDirectory: String,
        using fileManager: FileManager
    ) throws -> [(url: URL, path: String)] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: []
        )

        var files: [(url: URL, path: String)] = []
        for child in children {
            let values = try child.resourceValues(forKeys: keys)
            let relativePath = relativeDirectory.isEmpty
                ? child.lastPathComponent
                : "\(relativeDirectory)/\(child.lastPathComponent)"
            if values.isSymbolicLink == true {
                continue
            }
            if values.isDirectory == true {
                files.append(
                    contentsOf: try markdownFiles(
                        in: child,
                        relativeTo: relativePath,
                        using: fileManager
                    )
                )
            } else if values.isRegularFile == true && child.pathExtension.lowercased() == "md" {
                files.append((url: child, path: relativePath))
            }
        }
        return files
    }

    private func firstLevelOneHeading(in contents: String) -> String? {
        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#") else { continue }

            let remainder = line.dropFirst()
            guard remainder.first?.isWhitespace == true else { continue }

            let title = remainder.trimmingCharacters(in: .whitespaces)
            if !title.isEmpty {
                return title
            }
        }
        return nil
    }
}
