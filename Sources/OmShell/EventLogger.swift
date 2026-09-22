import Foundation

public enum LogLevel: String, Codable, CaseIterable, Sendable {
    case debug
    case info
    case warn
    case error

    fileprivate var priority: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .warn: 2
        case .error: 3
        }
    }

    public static func from(environment: [String: String] = ProcessInfo.processInfo.environment) -> LogLevel {
        environment["OM_LOG_LEVEL"].flatMap { LogLevel(rawValue: $0.lowercased()) } ?? .info
    }
}

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case strings([String])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .strings(try container.decode([String].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .strings(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct LogEvent: Codable, Equatable, Sendable {
    public let ts: String
    public let level: LogLevel
    public let event: String
    public let fields: [String: JSONValue]

    public init(ts: String, level: LogLevel, event: String, fields: [String: JSONValue]) {
        self.ts = ts
        self.level = level
        self.event = event
        self.fields = fields
    }
}

public protocol EventRecording: Sendable {
    func record(level: LogLevel, event: String, fields: [String: JSONValue])
}

public final class JSONEventLogger: EventRecording, @unchecked Sendable {
    public static let defaultMaximumBytes = 5 * 1_024 * 1_024

    public static var defaultLogURL: URL {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/om", isDirectory: true)
            .appendingPathComponent("om.log")
    }

    private let logURL: URL
    private let minimumLevel: LogLevel
    private let maximumBytes: Int
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let formatter: ISO8601DateFormatter

    public init(
        logURL: URL = JSONEventLogger.defaultLogURL,
        minimumLevel: LogLevel = .from(),
        maximumBytes: Int = JSONEventLogger.defaultMaximumBytes,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        self.logURL = logURL
        self.minimumLevel = minimumLevel
        self.maximumBytes = maximumBytes
        self.now = now

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        self.formatter = formatter

        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    public func record(
        level: LogLevel,
        event: String,
        fields: [String: JSONValue] = [:]
    ) {
        guard level.priority >= minimumLevel.priority else { return }
        lock.lock()
        defer { lock.unlock() }

        do {
            let entry = LogEvent(
                ts: formatter.string(from: now()),
                level: level,
                event: event,
                fields: fields
            )
            var data = try encoder.encode(entry)
            data.append(0x0A)
            try rotateIfNeeded(for: data.count)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            // Logging must never make a user operation fail.
        }
    }

    private func rotateIfNeeded(for incomingBytes: Int) throws {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue + incomingBytes > maximumBytes else { return }

        let rotatedURL = logURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: rotatedURL)
        try FileManager.default.moveItem(at: logURL, to: rotatedURL)
    }
}

public enum EventLogReader {
    public static func tail(_ count: Int = 50, from logURL: URL = JSONEventLogger.defaultLogURL) throws -> String {
        guard count > 0 else { return "[]\n" }
        guard FileManager.default.fileExists(atPath: logURL.path) else { return "[]\n" }
        let contents = try String(contentsOf: logURL, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return "[]\n" }
        return lines.suffix(count).joined(separator: "\n") + "\n"
    }
}

public enum EventLogCommandError: Error {
    case invalidArguments
}

public enum EventLogCommand {
    public static func output(
        arguments: [String],
        logURL: URL = JSONEventLogger.defaultLogURL
    ) throws -> String {
        let count: Int
        if arguments.isEmpty {
            count = 50
        } else if arguments.count == 2,
                  arguments[0] == "--tail",
                  let requested = Int(arguments[1]), requested >= 0 {
            count = requested
        } else {
            throw EventLogCommandError.invalidArguments
        }
        return try EventLogReader.tail(count, from: logURL)
    }
}
