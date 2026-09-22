import Foundation

public enum EditorMarkupAdapter {
    private static let identifierPrefix = "om-v1:"
    private static let expression = try! NSRegularExpression(pattern: #"\[\[([^\[\]\r\n]+)\]\]"#)

    private struct Payload: Codable {
        let destination: String
        let alias: String
        let displayAlias: String
    }

    public static func encode(_ source: String) -> String {
        rewrite(source) { body in
            let parts = body.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let alias = String(parts[1])
            let displayAlias = alias.replacingOccurrences(of: "|", with: "∣")
            let payload = Payload(destination: String(parts[0]), alias: alias, displayAlias: displayAlias)
            return displayAlias + "|" + encoded(payload)
        }
    }

    public static func decode(_ editorText: String) -> String {
        rewrite(editorText) { body in
            let parts = body.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let payload = decoded(String(parts[1])) else { return nil }
            let displayed = String(parts[0])
            let alias = displayed == payload.displayAlias
                ? payload.alias
                : displayed.replacingOccurrences(of: "∣", with: "|")
            return payload.destination + "|" + alias
        }
    }

    public static func destination(from identifier: String) -> String {
        decoded(identifier)?.destination ?? identifier
    }

    private static func encoded(_ payload: Payload) -> String {
        identifierPrefix + (try! JSONEncoder().encode(payload)).base64EncodedString()
    }

    private static func decoded(_ identifier: String) -> Payload? {
        guard identifier.hasPrefix(identifierPrefix),
              let data = Data(base64Encoded: String(identifier.dropFirst(identifierPrefix.count))) else {
            return nil
        }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    private static func rewrite(_ source: String, transform: (String) -> String?) -> String {
        let value = source as NSString
        let matches = expression.matches(
            in: source,
            range: NSRange(location: 0, length: value.length)
        )
        var result = source
        for match in matches.reversed() {
            let body = value.substring(with: match.range(at: 1))
            guard let replacement = transform(body),
                  let range = Range(match.range(at: 1), in: result) else { continue }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }
}
