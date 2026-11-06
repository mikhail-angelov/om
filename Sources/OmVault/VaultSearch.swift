import Foundation

public struct VaultSearchMatch: Codable, Equatable, Sendable {
    public let path: String
    public let line: Int
    public let text: String

    public init(path: String, line: Int, text: String) {
        self.path = path
        self.line = line
        self.text = text
    }
}

public struct VaultSearchReport: Codable, Equatable, Sendable {
    public let matches: [VaultSearchMatch]

    public init(matches: [VaultSearchMatch]) {
        self.matches = matches
    }
}

public struct VaultSearcher: Sendable {
    public init() {}

    public func search(vaultAt vaultURL: URL, query: String) throws -> VaultSearchReport {
        let inventory = try VaultIndexer().index(vaultAt: vaultURL)
        let root = vaultURL.standardizedFileURL
        var matches: [VaultSearchMatch] = []

        for note in inventory.notes {
            // Sealed and binary files are in the inventory but have no lines to
            // match: a search must not report bytes it cannot read.
            guard let contents = try VaultFile.text(
                at: root.appendingPathComponent(note.path)
            ) else { continue }

            for (index, line) in contents.components(separatedBy: .newlines).enumerated()
            where line.range(of: query, options: .caseInsensitive) != nil {
                matches.append(
                    VaultSearchMatch(path: note.path, line: index + 1, text: line)
                )
            }
        }

        return VaultSearchReport(matches: matches)
    }
}
