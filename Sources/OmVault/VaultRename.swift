import Foundation

public struct VaultRenamedNote: Codable, Equatable, Sendable {
    public let from: String
    public let to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

public struct VaultUpdatedFile: Codable, Equatable, Sendable {
    public let path: String
    public let links: Int

    public init(path: String, links: Int) {
        self.path = path
        self.links = links
    }
}

public struct VaultRenameReport: Codable, Equatable, Sendable {
    public let renamed: VaultRenamedNote
    public let updated: [VaultUpdatedFile]
    public let skipped: [String]

    public init(
        renamed: VaultRenamedNote,
        updated: [VaultUpdatedFile],
        skipped: [String]
    ) {
        self.renamed = renamed
        self.updated = updated
        self.skipped = skipped
    }
}

public enum VaultRenameError: LocalizedError, Equatable {
    case noteNotFound(String)
    case invalidName(String)
    case destinationOccupied(String)
    case inconsistentLinks(String)

    public var errorDescription: String? {
        switch self {
        case .noteNotFound(let name):
            return "Note not found: \(name)"
        case .invalidName(let name):
            return "Invalid note name: \(name)"
        case .destinationOccupied(let name):
            return "Destination note already exists: \(name)"
        case .inconsistentLinks(let path):
            return "Could not safely update links in: \(path)"
        }
    }
}

public struct VaultRenamer: Sendable {
    public init() {}

    public func rename(
        vaultAt vaultURL: URL,
        from oldName: String,
        to newName: String
    ) throws -> VaultRenameReport {
        let inventory = try VaultIndexer().index(vaultAt: vaultURL)
        let requestedOldName = (oldName as NSString).lastPathComponent
        let requestedNewName = (newName as NSString).lastPathComponent
        let oldBaseName = normalizedName(oldName)
        guard !oldBaseName.isEmpty else { throw VaultRenameError.invalidName(oldName) }
        guard !requestedNewName.isEmpty else { throw VaultRenameError.invalidName(newName) }

        // Either spelling finds the note: the filename as it sits on disk, or
        // the bare name links use.
        guard let target = inventory.notes.first(where: {
            ($0.path as NSString).lastPathComponent
                .caseInsensitiveCompare(requestedOldName) == .orderedSame
                || noteBaseName($0).caseInsensitiveCompare(oldBaseName) == .orderedSame
        }) else {
            throw VaultRenameError.noteNotFound(oldName)
        }

        // A rename keeps the file's kind: `notes.txt` becomes `<new>.txt`, and
        // an extension the caller already spelled out is not appended twice.
        let targetExtension = (target.path as NSString).pathExtension
        let spellsTargetExtension = (requestedNewName as NSString).pathExtension
            .caseInsensitiveCompare(targetExtension) == .orderedSame
        let destinationFilename = targetExtension.isEmpty || spellsTargetExtension
            ? requestedNewName
            : "\(requestedNewName).\(targetExtension)"
        let targetBaseName = noteBaseName(target)
        let newBaseName = targetExtension.isEmpty
            ? destinationFilename
            : (destinationFilename as NSString).deletingPathExtension
        guard !newBaseName.isEmpty else { throw VaultRenameError.invalidName(newName) }

        let targetDirectory = (target.path as NSString).deletingLastPathComponent
        let destinationPath = targetDirectory.isEmpty
            ? destinationFilename
            : "\(targetDirectory)/\(destinationFilename)"
        let root = vaultURL.standardizedFileURL
        let destinationURL = root.appendingPathComponent(destinationPath)
        let fileManager = FileManager.default

        let nameIsOccupied = inventory.notes.contains {
            noteBaseName($0).caseInsensitiveCompare(newBaseName) == .orderedSame
        }
        guard !nameIsOccupied, !fileManager.fileExists(atPath: destinationURL.path) else {
            throw VaultRenameError.destinationOccupied(newName)
        }

        let links = try VaultLinkInspector().inspect(vaultAt: root).links
        let expectedCounts = links
            .filter { $0.resolved == target.path }
            .reduce(into: [String: Int]()) { counts, link in
                counts[link.from, default: 0] += 1
            }

        var changes: [(url: URL, contents: String, updated: VaultUpdatedFile)] = []
        for note in inventory.notes {
            guard let expectedCount = expectedCounts[note.path] else { continue }
            let noteURL = root.appendingPathComponent(note.path)
            guard let contents = try VaultFile.text(at: noteURL) else { continue }
            let rewritten = rewriteLinks(
                in: contents,
                from: targetBaseName,
                to: newBaseName,
                fileExtension: targetExtension
            )
            guard rewritten.count == expectedCount else {
                throw VaultRenameError.inconsistentLinks(note.path)
            }
            guard rewritten.contents != contents else { continue }

            changes.append(
                (
                    url: noteURL,
                    contents: rewritten.contents,
                    updated: VaultUpdatedFile(
                        path: note.path == target.path ? destinationPath : note.path,
                        links: rewritten.count
                    )
                )
            )
        }

        for change in changes {
            try Data(change.contents.utf8).write(to: change.url)
        }
        try fileManager.moveItem(
            at: root.appendingPathComponent(target.path),
            to: destinationURL
        )

        return VaultRenameReport(
            renamed: VaultRenamedNote(from: target.path, to: destinationPath),
            updated: changes.map(\.updated).sorted { $0.path < $1.path },
            skipped: []
        )
    }

    private func normalizedName(_ name: String) -> String {
        let filename = (name as NSString).lastPathComponent
        return (filename as NSString).pathExtension.lowercased() == "md"
            ? (filename as NSString).deletingPathExtension
            : filename
    }

    private func noteBaseName(_ note: VaultNote) -> String {
        let filename = (note.path as NSString).lastPathComponent
        return (filename as NSString).deletingPathExtension
    }

    private func rewriteLinks(
        in contents: String,
        from oldName: String,
        to newName: String,
        fileExtension: String
    ) -> (contents: String, count: Int) {
        var fence: Fence?
        var replacementCount = 0
        let lines = contents.components(separatedBy: "\n").map { line -> String in
            if let activeFence = fence {
                if isClosingFence(line, matching: activeFence) {
                    fence = nil
                }
                return line
            }
            if let openingFence = openingFence(in: line) {
                fence = openingFence
                return line
            }
            if line.hasPrefix("    ") || line.hasPrefix("\t") {
                return line
            }

            let rewritten = rewriteLinksInLine(
                line, from: oldName, to: newName, fileExtension: fileExtension
            )
            replacementCount += rewritten.count
            return rewritten.line
        }

        return (lines.joined(separator: "\n"), replacementCount)
    }

    private func rewriteLinksInLine(
        _ line: String,
        from oldName: String,
        to newName: String,
        fileExtension: String
    ) -> (line: String, count: Int) {
        guard let expression = try? NSRegularExpression(pattern: #"\[\[([^\[\]\r\n]+)\]\]"#) else {
            return (line, 0)
        }

        let masked = maskingInlineCode(in: line)
        let matches = expression.matches(
            in: masked,
            range: NSRange(location: 0, length: (masked as NSString).length)
        )
        let rewritten = NSMutableString(string: line)
        var count = 0

        for match in matches.reversed() {
            let bodyRange = match.range(at: 1)
            let body = (line as NSString).substring(with: bodyRange) as NSString
            let hash = body.range(of: "#").location
            let pipe = body.range(of: "|").location
            let separator = min(hash, pipe)
            let targetLength = separator == NSNotFound ? body.length : separator
            let rawTarget = body.substring(with: NSRange(location: 0, length: targetLength)) as NSString
            let nonWhitespace = CharacterSet.whitespaces.inverted
            let first = rawTarget.rangeOfCharacter(from: nonWhitespace)
            let last = rawTarget.rangeOfCharacter(from: nonWhitespace, options: .backwards)
            guard first.location != NSNotFound, last.location != NSNotFound else { continue }

            let trimmedRange = NSRange(
                location: first.location,
                length: last.location + last.length - first.location
            )
            let target = rawTarget.substring(with: trimmedRange)
            let filename = (target as NSString).lastPathComponent
            let linkExtension = (filename as NSString).pathExtension
            // A link may spell the renamed file's extension out or leave it
            // off; whichever it does is what the rewritten link keeps.
            let spellsExtension = !linkExtension.isEmpty
                && linkExtension.caseInsensitiveCompare(fileExtension) == .orderedSame
            let targetBaseName = spellsExtension
                ? (filename as NSString).deletingPathExtension
                : filename
            guard targetBaseName.caseInsensitiveCompare(oldName) == .orderedSame else { continue }

            let replacementFilename = spellsExtension
                ? "\(newName).\(linkExtension)"
                : newName
            let directory = (target as NSString).deletingLastPathComponent
            let replacement = directory.isEmpty || directory == "."
                ? replacementFilename
                : "\(directory)/\(replacementFilename)"
            let absoluteTargetRange = NSRange(
                location: bodyRange.location + trimmedRange.location,
                length: trimmedRange.length
            )
            rewritten.replaceCharacters(in: absoluteTargetRange, with: replacement)
            count += 1
        }

        return (rewritten as String, count)
    }

    private func maskingInlineCode(in line: String) -> String {
        let scalars = Array(line.unicodeScalars)
        var result = ""
        var delimiterLength: Int?
        var index = 0

        while index < scalars.count {
            if scalars[index] == "`" {
                var end = index
                while end < scalars.count && scalars[end] == "`" {
                    end += 1
                }
                let runLength = end - index
                if delimiterLength == nil {
                    delimiterLength = runLength
                } else if delimiterLength == runLength {
                    delimiterLength = nil
                }
                result.append(String(repeating: " ", count: runLength))
                index = end
            } else {
                let scalar = scalars[index]
                if delimiterLength == nil {
                    result.unicodeScalars.append(scalar)
                } else {
                    result.append(String(repeating: " ", count: scalar.utf16.count))
                }
                index += 1
            }
        }

        return result
    }

    private struct Fence {
        let marker: Character
        let length: Int
    }

    private func openingFence(in line: String) -> Fence? {
        let content = line.dropFirst(min(line.prefix(while: { $0 == " " }).count, 4))
        let indentation = line.count - content.count
        guard indentation <= 3, let marker = content.first, marker == "`" || marker == "~" else {
            return nil
        }
        let length = content.prefix(while: { $0 == marker }).count
        return length >= 3 ? Fence(marker: marker, length: length) : nil
    }

    private func isClosingFence(_ line: String, matching fence: Fence) -> Bool {
        let content = line.dropFirst(min(line.prefix(while: { $0 == " " }).count, 4))
        let indentation = line.count - content.count
        guard indentation <= 3 else { return false }

        let markerLength = content.prefix(while: { $0 == fence.marker }).count
        guard markerLength >= fence.length else { return false }
        return content.dropFirst(markerLength).allSatisfy(\.isWhitespace)
    }
}
