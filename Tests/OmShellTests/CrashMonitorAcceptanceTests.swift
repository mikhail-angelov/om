import Foundation
import XCTest

final class CrashMonitorAcceptanceTests: XCTestCase {
    func testSignalAndExceptionSelfTestsLeaveCrashEvents() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logURL = directory.appendingPathComponent("om.log")
        defer { try? FileManager.default.removeItem(at: directory) }

        let signal = try runEditor(selfTest: "signal", logURL: logURL)
        XCTAssertNotEqual(signal, 0)
        let exception = try runEditor(selfTest: "exception", logURL: logURL)
        XCTAssertNotEqual(exception, 0)

        let lines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let events = try lines.map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        XCTAssertEqual(events.map { $0["event"] as? String }, ["app.crash", "app.crash"])
        XCTAssertNotNil((events[0]["fields"] as? [String: Any])?["signal"])
        XCTAssertNotNil((events[1]["fields"] as? [String: Any])?["exception"])
        XCTAssertTrue(events.allSatisfy {
            (($0["fields"] as? [String: Any])?["stack"] as? [String])?.isEmpty == false
        })
    }

    private func runEditor(selfTest: String, logURL: URL) throws -> Int32 {
        let executable = try XCTUnwrap(editorExecutable())
        let process = Process()
        process.executableURL = executable
        var environment = ProcessInfo.processInfo.environment
        environment["OM_SELFTEST_CRASH"] = selfTest
        environment["OM_SELFTEST_LOG_PATH"] = logURL.path
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func editorExecutable() -> URL? {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while root.path != "/", !FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Package.swift").path
        ) {
            root.deleteLastPathComponent()
        }
        let build = root.appendingPathComponent(".build")
        let candidates = [
            build.appendingPathComponent("debug/OmEditor"),
            build.appendingPathComponent("arm64-apple-macosx/debug/OmEditor"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
