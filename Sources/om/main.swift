import Foundation
import OmVault

enum CommandError: LocalizedError {
    case usage

    var errorDescription: String? {
        "Usage: om <index|links> <vault> | om backlinks <vault> <note name>"
    }
}

func writeJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var output = try encoder.encode(value)
    output.append(0x0A)
    FileHandle.standardOutput.write(output)
}

do {
    let arguments = CommandLine.arguments
    guard arguments.count >= 2 else {
        throw CommandError.usage
    }

    switch arguments[1] {
    case "index":
        guard arguments.count == 3 else { throw CommandError.usage }
        let vaultURL = URL(fileURLWithPath: arguments[2], isDirectory: true)
        try writeJSON(VaultIndexer().index(vaultAt: vaultURL))
    case "links":
        guard arguments.count == 3 else { throw CommandError.usage }
        let vaultURL = URL(fileURLWithPath: arguments[2], isDirectory: true)
        try writeJSON(VaultLinkInspector().inspect(vaultAt: vaultURL))
    case "backlinks":
        guard arguments.count == 4 else { throw CommandError.usage }
        let vaultURL = URL(fileURLWithPath: arguments[2], isDirectory: true)
        try writeJSON(
            VaultBacklinkFinder().find(vaultAt: vaultURL, noteName: arguments[3])
        )
    default:
        throw CommandError.usage
    }
} catch {
    let message = "Error: \(error.localizedDescription)\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(1)
}
