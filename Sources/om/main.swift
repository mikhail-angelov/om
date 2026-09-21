import Foundation
import OmVault

enum CommandError: LocalizedError {
    case usage

    var errorDescription: String? {
        "Usage: om index <vault>"
    }
}

do {
    let arguments = CommandLine.arguments
    guard arguments.count == 3, arguments[1] == "index" else {
        throw CommandError.usage
    }

    let inventory = try VaultIndexer().index(
        vaultAt: URL(fileURLWithPath: arguments[2], isDirectory: true)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var output = try encoder.encode(inventory)
    output.append(0x0A)
    FileHandle.standardOutput.write(output)
} catch {
    let message = "Error: \(error.localizedDescription)\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(1)
}
