import Darwin
import Foundation
import OmCrashSupport

private nonisolated(unsafe) var installedCrashLogger: (any EventRecording)?

private func crashFields(reason: String, stack: [String]) -> [String: JSONValue] {
    ["reason": .string(reason), "stack": .strings(stack)]
}

private func handleSignal(_ number: Int32) {
    let reason = strsignal(number).map { String(cString: $0) } ?? "Signal \(number)"
    var fields = crashFields(reason: reason, stack: Thread.callStackSymbols)
    fields["signal"] = .integer(Int(number))
    installedCrashLogger?.record(level: .error, event: "app.crash", fields: fields)
    _exit(128 + number)
}

private func handleException(
    _ name: UnsafePointer<CChar>?,
    _ reason: UnsafePointer<CChar>?,
    _ stack: UnsafePointer<CChar>?
) {
    let exceptionName = name.map(String.init(cString:)) ?? "NSException"
    let exceptionReason = reason.map(String.init(cString:)) ?? "Uncaught Objective-C exception"
    let stackLines = stack.map { String(cString: $0).components(separatedBy: "\n") } ?? []
    var fields = crashFields(reason: exceptionReason, stack: stackLines)
    fields["exception"] = .string(exceptionName)
    installedCrashLogger?.record(level: .error, event: "app.crash", fields: fields)
    _exit(1)
}

public enum CrashMonitor {
    public static func install(logger: any EventRecording) {
        installedCrashLogger = logger
        OmInstallExceptionHandler(handleException)
        signal(SIGSEGV, handleSignal)
        signal(SIGABRT, handleSignal)
        signal(SIGILL, handleSignal)
        signal(SIGTRAP, handleSignal)
    }

    public static func runRequestedSelfTest(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        switch environment["OM_SELFTEST_CRASH"] {
        case "signal": raise(SIGABRT)
        case "exception": OmRaiseTestException()
        default: break
        }
    }
}
