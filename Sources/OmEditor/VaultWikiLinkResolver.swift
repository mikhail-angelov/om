import Foundation
import MarkdownEngine

struct VaultWikiLinkResolver: WikiLinkResolver {
    let resolvedIdentifiers: Set<String>

    func resolve(displayName: String, range: NSRange) -> WikiLinkResolution? {
        WikiLinkResolution(
            id: displayName,
            exists: resolvedIdentifiers.contains(displayName)
        )
    }

    func fingerprint() -> AnyHashable {
        AnyHashable(resolvedIdentifiers)
    }
}
