import Foundation
import OmVault
import SwiftUI

enum VaultEditorModelError: LocalizedError {
    case noNoteSelected
    case unknownNote(String)

    var errorDescription: String? {
        switch self {
        case .noNoteSelected:
            return "Select a note before editing."
        case .unknownNote(let path):
            return "The note is not in the open vault: \(path)"
        }
    }
}

@MainActor
final class VaultEditorModel: ObservableObject {
    @Published private(set) var vaultURL: URL?
    @Published private(set) var notes: [VaultNote] = []
    @Published private(set) var selectedPath: String?
    @Published private(set) var source = ""
    @Published private(set) var errorMessage: String?

    func openVault(at url: URL) throws {
        let inventory = try VaultIndexer().index(vaultAt: url)

        vaultURL = url.standardizedFileURL
        notes = inventory.notes
        selectedPath = nil
        source = ""
        errorMessage = nil
    }

    func selectNote(at path: String?) throws {
        guard let path else {
            selectedPath = nil
            source = ""
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
        errorMessage = nil
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
}
