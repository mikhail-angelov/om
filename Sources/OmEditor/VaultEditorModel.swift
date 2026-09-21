import Foundation
import OmVault
import SwiftUI

enum VaultEditorModelError: LocalizedError {
    case noNoteSelected
    case unknownNote(String)
    case unresolvedLink(String)

    var errorDescription: String? {
        switch self {
        case .noNoteSelected:
            return "Select a note before editing."
        case .unknownNote(let path):
            return "The note is not in the open vault: \(path)"
        case .unresolvedLink(let link):
            return "No note in the open vault matches the link: \(link)"
        }
    }
}

@MainActor
final class VaultEditorModel: ObservableObject {
    @Published private(set) var vaultURL: URL?
    @Published private(set) var notes: [VaultNote] = []
    @Published private(set) var selectedPath: String?
    @Published private(set) var source = ""
    @Published private(set) var resolvedLinkIdentifiers: Set<String> = []
    @Published private(set) var errorMessage: String?

    private var linksReport = VaultLinksReport(links: [], broken: [])

    func openVault(at url: URL) throws {
        let inventory = try VaultIndexer().index(vaultAt: url)
        let report = try VaultLinkInspector().inspect(vaultAt: url)

        vaultURL = url.standardizedFileURL
        notes = inventory.notes
        selectedPath = nil
        source = ""
        resolvedLinkIdentifiers = []
        linksReport = report
        errorMessage = nil
    }

    func selectNote(at path: String?) throws {
        guard let path else {
            selectedPath = nil
            source = ""
            resolvedLinkIdentifiers = []
            return
        }
        guard notes.contains(where: { $0.path == path }), let vaultURL else {
            throw VaultEditorModelError.unknownNote(path)
        }

        let loadedSource = try String(
            contentsOf: vaultURL.appendingPathComponent(path),
            encoding: .utf8
        )
        selectedPath = path
        source = loadedSource
        resolvedLinkIdentifiers = identifiers(forLinksFrom: path, in: linksReport)
        errorMessage = nil
    }

    func updateSource(_ newSource: String) throws {
        guard let vaultURL, let selectedPath else {
            throw VaultEditorModelError.noNoteSelected
        }

        try newSource.write(
            to: vaultURL.appendingPathComponent(selectedPath),
            atomically: true,
            encoding: .utf8
        )
        source = newSource
        linksReport = try VaultLinkInspector().inspect(vaultAt: vaultURL)
        resolvedLinkIdentifiers = identifiers(forLinksFrom: selectedPath, in: linksReport)
        errorMessage = nil
    }

    func followWikiLink(_ identifier: String) throws {
        guard let vaultURL, let selectedPath else {
            throw VaultEditorModelError.noNoteSelected
        }

        let report = try VaultLinkInspector().inspect(vaultAt: vaultURL)
        guard let resolvedPath = report.links.first(where: {
            $0.from == selectedPath && editorIdentifier(for: $0) == identifier
        })?.resolved else {
            throw VaultEditorModelError.unresolvedLink(identifier)
        }

        linksReport = report
        try selectNote(at: resolvedPath)
    }

    func openVaultFromUI(at url: URL) {
        captureError { try openVault(at: url) }
    }

    func selectNoteFromUI(at path: String?) {
        captureError { try selectNote(at: path) }
    }

    func updateSourceFromUI(_ newSource: String) {
        captureError { try updateSource(newSource) }
    }

    func followWikiLinkFromUI(_ identifier: String) {
        captureError { try followWikiLink(identifier) }
    }

    func clearError() {
        errorMessage = nil
    }

    private func captureError(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func identifiers(
        forLinksFrom sourcePath: String,
        in report: VaultLinksReport
    ) -> Set<String> {
        Set(
            report.links
                .filter { $0.from == sourcePath }
                .map(editorIdentifier(for:))
        )
    }

    private func editorIdentifier(for link: VaultLink) -> String {
        if let alias = link.alias {
            return alias
        }
        if let anchor = link.anchor {
            return "\(link.target)#\(anchor)"
        }
        return link.target
    }
}
