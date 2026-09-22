import Foundation
import XCTest
@testable import OmShell

final class EventLoggerTests: XCTestCase {
    func testLoggerWritesFilteredJSONLinesAndRotatesBeforeLimit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logURL = directory.appendingPathComponent("om.log")
        defer { try? FileManager.default.removeItem(at: directory) }

        let logger = try JSONEventLogger(
            logURL: logURL,
            minimumLevel: .info,
            maximumBytes: 1,
            now: { Date(timeIntervalSince1970: 0) }
        )
        logger.record(level: .debug, event: "hidden", fields: [:])
        logger.record(level: .info, event: "first", fields: ["value": .string("one")])
        logger.record(level: .error, event: "second", fields: ["count": .integer(2)])

        let current = try String(contentsOf: logURL, encoding: .utf8)
        let rotated = try String(contentsOf: logURL.appendingPathExtension("1"), encoding: .utf8)
        XCTAssertFalse(current.contains("hidden"))
        XCTAssertTrue(rotated.contains("\"event\":\"first\""))
        XCTAssertTrue(current.contains("\"event\":\"second\""))
        XCTAssertTrue(current.contains("1970-01-01T00:00:00.000Z"))
    }

    func testTailReturnsExactLastLinesAndMissingLogIsEmptyArray() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logURL = directory.appendingPathComponent("om.log")
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(try EventLogReader.tail(50, from: logURL), "[]\n")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "{\"n\":1}\n{\"n\":2}\n{\"n\":3}\n".write(
            to: logURL, atomically: true, encoding: .utf8
        )
        XCTAssertEqual(try EventLogReader.tail(2, from: logURL), "{\"n\":2}\n{\"n\":3}\n")
    }
}
