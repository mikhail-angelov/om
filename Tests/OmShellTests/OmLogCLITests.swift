import Foundation
import XCTest
@testable import OmShell

final class OmLogCLITests: XCTestCase {
    func testLogCommandPrintsTailAndMissingLogAsEmptyArray() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logURL = directory.appendingPathComponent("om.log")
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(try EventLogCommand.output(arguments: [], logURL: logURL), "[]\n")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "{\"n\":1}\n{\"n\":2}\n{\"n\":3}\n".write(
            to: logURL, atomically: true, encoding: .utf8
        )
        XCTAssertEqual(
            try EventLogCommand.output(arguments: ["--tail", "2"], logURL: logURL),
            "{\"n\":2}\n{\"n\":3}\n"
        )
        XCTAssertThrowsError(
            try EventLogCommand.output(arguments: ["--tail", "nope"], logURL: logURL)
        )
    }
}
