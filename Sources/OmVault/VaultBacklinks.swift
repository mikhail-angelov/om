import Foundation

public struct VaultBacklinksReport: Codable, Equatable, Sendable {
    public let backlinks: [String]

    public init(backlinks: [String]) {
        self.backlinks = backlinks
    }
}

public enum VaultBacklinkError: LocalizedError, Equatable {
    case noteNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .noteNotFound(let name):
            return "Note not found: \(name)"
        }
    }
}

public struct VaultBacklinkFinder: Sendable {
    public init() {}

    public func find(vaultAt vaultURL: URL, noteName: String) throws -> VaultBacklinksReport {
        let inventory = try VaultIndexer().index(vaultAt: vaultURL)
        let requestedFilename = (noteName as NSString).lastPathComponent
        let requestedName = (requestedFilename as NSString).pathExtension.lowercased() == "md"
            ? (requestedFilename as NSString).deletingPathExtension
            : requestedFilename

        guard let target = inventory.notes.first(where: { note in
            let filename = (note.path as NSString).lastPathComponent
            return (filename as NSString).deletingPathExtension
                .caseInsensitiveCompare(requestedName) == .orderedSame
        }) else {
            throw VaultBacklinkError.noteNotFound(noteName)
        }

        let links = try VaultLinkInspector().inspect(vaultAt: vaultURL).links
        let backlinks = Set(
            links.lazy
                .filter { $0.resolved == target.path }
                .map(\.from)
        ).sorted()

        return VaultBacklinksReport(backlinks: backlinks)
    }
}
