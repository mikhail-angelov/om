import Foundation

public struct VaultLink: Codable, Equatable, Sendable {
    public let from: String
    public let target: String
    public let resolved: String?
    public let anchor: String?
    public let alias: String?

    public init(
        from: String,
        target: String,
        resolved: String? = nil,
        anchor: String? = nil,
        alias: String? = nil
    ) {
        self.from = from
        self.target = target
        self.resolved = resolved
        self.anchor = anchor
        self.alias = alias
    }
}

public struct VaultLinksReport: Codable, Equatable, Sendable {
    public let links: [VaultLink]
    public let broken: [VaultLink]

    public init(links: [VaultLink], broken: [VaultLink]) {
        self.links = links
        self.broken = broken
    }
}

public struct VaultLinkInspector: Sendable {
    public init() {}

    public func inspect(vaultAt vaultURL: URL) throws -> VaultLinksReport {
        let inventory = try VaultIndexer().index(vaultAt: vaultURL)
        let root = vaultURL.standardizedFileURL
        // A note is addressable by its bare name and by its full filename. The
        // second key is what makes `[[notes.txt]]` resolve now that a vault
        // holds more than Markdown.
        let destinations = inventory.notes.reduce(into: [String: String]()) { result, note in
            let filename = (note.path as NSString).lastPathComponent
            let name = (filename as NSString).deletingPathExtension.lowercased()
            if result[name] == nil {
                result[name] = note.path
            }
            if result[filename.lowercased()] == nil {
                result[filename.lowercased()] = note.path
            }
        }

        var links: [VaultLink] = []
        var broken: [VaultLink] = []

        for note in inventory.notes {
            guard let contents = try VaultFile.text(
                at: root.appendingPathComponent(note.path)
            ) else { continue }

            for parsed in parseLinks(in: contents) {
                let filename = (parsed.target as NSString).lastPathComponent
                let bareName = (filename as NSString).deletingPathExtension
                let resolved = destinations[filename.lowercased()]
                    ?? destinations[bareName.lowercased()]
                let link = VaultLink(
                    from: note.path,
                    target: parsed.target,
                    resolved: resolved,
                    anchor: parsed.anchor,
                    alias: parsed.alias
                )

                if resolved == nil {
                    broken.append(link)
                } else {
                    links.append(link)
                }
            }
        }

        return VaultLinksReport(links: links, broken: broken)
    }

    private func parseLinks(in contents: String) -> [(target: String, anchor: String?, alias: String?)] {
        var parsed: [(target: String, anchor: String?, alias: String?)] = []
        var fence: Fence?

        for line in contents.components(separatedBy: .newlines) {
            if let activeFence = fence {
                if isClosingFence(line, matching: activeFence) {
                    fence = nil
                }
                continue
            }
            if let openingFence = openingFence(in: line) {
                fence = openingFence
                continue
            }
            if line.hasPrefix("    ") || line.hasPrefix("\t") {
                continue
            }

            parsed.append(contentsOf: links(in: removingInlineCode(from: line)))
        }

        return parsed
    }

    private func links(in line: String) -> [(target: String, anchor: String?, alias: String?)] {
        guard let expression = try? NSRegularExpression(pattern: #"\[\[([^\[\]\r\n]+)\]\]"#) else {
            return []
        }

        let string = line as NSString
        let matches = expression.matches(
            in: line,
            range: NSRange(location: 0, length: string.length)
        )

        return matches.compactMap { match in
            let body = string.substring(with: match.range(at: 1))
            let aliasParts = body.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let targetParts = aliasParts[0].split(
                separator: "#",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            let target = String(targetParts[0]).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { return nil }

            return (
                target: target,
                anchor: optionalTrimmed(targetParts.count == 2 ? String(targetParts[1]) : nil),
                alias: optionalTrimmed(aliasParts.count == 2 ? String(aliasParts[1]) : nil)
            )
        }
    }

    private func optionalTrimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func removingInlineCode(from line: String) -> String {
        let characters = Array(line)
        var result = ""
        var delimiterLength: Int?
        var index = 0

        while index < characters.count {
            if characters[index] == "`" {
                var end = index
                while end < characters.count && characters[end] == "`" {
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
                result.append(delimiterLength == nil ? characters[index] : " ")
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
