import Foundation
import XCTest

/// Acceptance tests for the VA-003 slice: `om backlinks <vault> <note name>`.
///
/// The use case is "Find notes that link to a requested note": a user or local
/// tool runs `om backlinks <vault> <note name>` and receives a sorted JSON list
/// of every note containing at least one real link to the requested note.
///
/// These tests drive the `om` executable as a subprocess — the same boundary a
/// user or local tool actually crosses — and assert the JSON it writes to
/// stdout and its exit status. The current checkout implements only `om index`
/// and `om links`, so every backlinks test here fails until the VA-003 behavior
/// exists.
final class OmVaultBacklinksAcceptanceTests: XCTestCase {

    // MARK: - Locations

    /// The package root, found by walking up from this source file to the
    /// directory containing `Package.swift`.
    private var packageRoot: URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        while url.path != "/" {
            if fm.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return url
    }

    /// The fixture vault used by the backlinks tests. It lives in the source
    /// tree (allowed under `Tests/**/Resources/**`) and is located relative to
    /// this file, so no bundle-resource declaration in `Package.swift` is
    /// needed.
    private var vaultURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/BacklinksVault")
    }

    /// Locates the built `om` executable. `swift test` also builds the
    /// executable target, so the binary is available under `.build/...`.
    private func locateOmExecutable() -> URL? {
        let fm = FileManager.default
        let build = packageRoot.appendingPathComponent(".build")
        let candidates = [
            build.appendingPathComponent("debug/om"),
            build.appendingPathComponent("release/om"),
            build.appendingPathComponent("arm64-apple-macosx/debug/om"),
            build.appendingPathComponent("arm64-apple-macosx/release/om"),
        ]
        for candidate in candidates where fm.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        // Fallback: search the build tree for the first executable named "om".
        guard let enumerator = fm.enumerator(atPath: build.path) else { return nil }
        for case let path as String in enumerator {
            guard (path as NSString).lastPathComponent == "om" else { continue }
            let full = build.appendingPathComponent(path)
            if fm.isExecutableFile(atPath: full.path) { return full }
        }
        return nil
    }

    // MARK: - Helpers

    private struct RunResult {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data
    }

    /// Runs `om` with the given arguments and captures stdout, stderr and the
    /// exit code, using Foundation's `Process`/`Pipe` — the standard facility
    /// for driving a command-line program.
    private func runOm(_ arguments: [String]) throws -> RunResult {
        let executable = try XCTUnwrap(
            locateOmExecutable(),
            "The built `om` executable was not found under \(packageRoot.appendingPathComponent(".build").path). Build the package first."
        )
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return RunResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    /// Runs `om backlinks <vault> <note name>` and returns the process result
    /// together with the parsed `backlinks` array. When the exit code is
    /// nonzero the parsed array is `nil`, because a failed run may not have
    /// written JSON to stdout at all.
    private func runBacklinks(for noteName: String) throws -> (result: RunResult, backlinks: [String]?) {
        let result = try runOm(["backlinks", vaultURL.path, noteName])
        guard result.exitCode == 0 else { return (result, nil) }

        let object = try JSONSerialization.jsonObject(with: result.stdout, options: [])
        let root = try XCTUnwrap(object as? [String: Any], "Expected a JSON object, got \(object)")
        let backlinks = try XCTUnwrap(root["backlinks"] as? [String], "Expected a `backlinks` array of strings, got \(root)")
        return (result, backlinks)
    }

    // MARK: - Criterion 1

    /// A vault with several notes linking to the requested note (one of them
    /// more than once) yields each referring relative path exactly once, in
    /// ascending order.
    func testBacklinksListEachReferringPathOnceSortedAscending() throws {
        let (result, backlinks) = try runBacklinks(for: "Target")

        XCTAssertEqual(result.exitCode, 0, "`om backlinks <vault> Target` must exit 0 on success")
        let list = try XCTUnwrap(backlinks, "`om backlinks <vault> Target` must emit a JSON object with a `backlinks` array")

        // Alpha.md, Code Samples.md, Nested/Deep.md and Variants.md each link
        // once; Beta.md links twice. Every referring path must appear exactly
        // once, and the array must be sorted ascending.
        XCTAssertEqual(
            list,
            ["Alpha.md", "Beta.md", "Code Samples.md", "Nested/Deep.md", "Variants.md"],
            "Every note linking to Target must appear exactly once, sorted ascending"
        )

        // The double link in Beta.md must not produce a duplicate entry.
        XCTAssertEqual(
            list.filter { $0 == "Beta.md" }.count, 1,
            "A note linking more than once to the target must still appear exactly once"
        )

        // The requested note itself does not link to Target, so it must not
        // appear, and neither must the code-only note or the self-linking note.
        XCTAssertFalse(list.contains("Target.md"), "Target.md does not link to itself")
        XCTAssertFalse(list.contains("CodeOnly.md"), "CodeOnly.md links to Target only inside code")
        XCTAssertFalse(list.contains("Self.md"), "Self.md links only to itself")
    }

    // MARK: - Criterion 2

    /// A note containing a valid link to itself appears in its own backlinks.
    func testSelfLinkIsIncludedInOwnBacklinks() throws {
        let (result, backlinks) = try runBacklinks(for: "Self")

        XCTAssertEqual(result.exitCode, 0, "`om backlinks <vault> Self` must exit 0 on success")
        let list = try XCTUnwrap(backlinks, "`om backlinks <vault> Self` must emit a JSON object with a `backlinks` array")
        XCTAssertEqual(
            list, ["Self.md"],
            "A note that links to itself must be listed among its own backlinks"
        )
    }

    // MARK: - Criterion 3

    /// Wikilink-looking text inside inline code, backtick fences, tilde fences
    /// or indented blocks produces no backlink.
    func testWikilinkInsideCodeProducesNoBacklink() throws {
        let (result, backlinks) = try runBacklinks(for: "Target")

        XCTAssertEqual(result.exitCode, 0, "`om backlinks <vault> Target` must exit 0 on success")
        let list = try XCTUnwrap(backlinks, "`om backlinks <vault> Target` must emit a JSON object with a `backlinks` array")

        // CodeOnly.md mentions `[[Target]]` only inside the four excluded code
        // contexts, so it must never show up as a referring note.
        XCTAssertFalse(
            list.contains("CodeOnly.md"),
            "Wikilink-looking text inside code must not produce a backlink"
        )
    }

    // MARK: - Criterion 4

    /// The requested note resolves case-insensitively and extension-tolerantly,
    /// matching the resolution behavior of `om links`; a successful run writes
    /// valid JSON and exits 0.
    func testBacklinksResolveRequestedNoteCaseInsensitivelyAndExtensionTolerantAndEmitValidJsonExitZero() throws {
        // All four spellings of the same note name must resolve to Target.md.
        let spellings = ["Target", "target", "Target.md", "TARGET.md"]
        var lists: [[String]] = []
        for name in spellings {
            let (result, backlinks) = try runBacklinks(for: name)
            XCTAssertEqual(result.exitCode, 0, "`om backlinks <vault> \(name)` must exit 0")
            // Parsing through JSONSerialization also proves stdout is valid JSON.
            lists.append(try XCTUnwrap(backlinks, "`om backlinks <vault> \(name)` must emit a JSON object with a `backlinks` array"))
        }

        // Case and extension variants of the note name must yield the same set.
        for list in lists.dropFirst() {
            XCTAssertEqual(list, lists[0], "case and `.md` variants of the note name must resolve to the same note")
        }

        // The links inside Variants.md are written `[[target]]`, `[[Target.md]]`
        // and `[[TARGET]]`; every one must count as a link to Target.md, so the
        // note appears regardless of which spelling was requested.
        XCTAssertTrue(
            lists[0].contains("Variants.md"),
            "links written `[[target]]`, `[[Target.md]]` and `[[TARGET]]` must all resolve to Target.md"
        )
    }
}
