import Foundation
import XCTest

/// Acceptance tests for the VA-005 slice: `om search <vault> <query>`.
///
/// The use case is "Search note text across a vault": a user or local tool runs
/// `om search <vault> <query>` and receives every case-insensitive substring
/// match with its note-relative `path`, one-based `line` number and the
/// complete source line `text`, in deterministic order (path ascending, then
/// line ascending).
///
/// These tests drive the `om` executable as a subprocess — the same boundary a
/// user or local tool actually crosses — and assert the JSON it writes to
/// stdout, its exit status, and its stderr on failure. The current checkout
/// implements only `om index`, `om links`, `om backlinks` and `om rename`;
/// `om search` is not wired up, so every search test here fails until the
/// VA-005 behavior exists.
final class OmVaultSearchAcceptanceTests: XCTestCase {

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

    /// The fixture vault used by the search tests. It lives in the source tree
    /// (allowed under `Tests/**/Resources/**`) and is located relative to this
    /// file, so no bundle-resource declaration in `Package.swift` is needed.
    private var vaultURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/SearchVault")
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

    private struct Match: Equatable {
        let path: String
        let line: Int
        let text: String
    }

    /// Parses the single JSON document a successful `om search` writes to
    /// stdout. `JSONSerialization` rejects trailing garbage, so a successful
    /// parse also proves stdout carries exactly one valid JSON document.
    private func parseMatches(_ data: Data) throws -> [Match] {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        let root = try XCTUnwrap(object as? [String: Any], "search stdout must be a JSON object, got \(object)")
        let rawMatches = try XCTUnwrap(root["matches"] as? [[String: Any]], "expected a `matches` array, got \(root)")
        return try rawMatches.map { raw in
            Match(
                path: try XCTUnwrap(raw["path"] as? String, "match missing string `path`: \(raw)"),
                line: try XCTUnwrap(raw["line"] as? Int, "match missing integer `line`: \(raw)"),
                text: try XCTUnwrap(raw["text"] as? String, "match missing string `text`: \(raw)")
            )
        }
    }

    /// Runs `om search <vault> <query>` and returns the process result together
    /// with the parsed `matches` array. When the exit code is nonzero the
    /// parsed array is `nil`, because a failed run may not have written JSON to
    /// stdout at all.
    private func runSearch(_ query: String) throws -> (result: RunResult, matches: [Match]?) {
        let result = try runOm(["search", vaultURL.path, query])
        guard result.exitCode == 0 else { return (result, nil) }
        return (result, try parseMatches(result.stdout))
    }

    // MARK: - Criterion 1

    /// Searching with casing different from the stored text still finds the
    /// substring and emits a top-level `matches` array whose entries carry the
    /// note-relative `path`, one-based `line` and the full line `text`.
    func testSearchMatchesCaseInsensitiveSubstringWithPathLineAndText() throws {
        // The fixture stores "quark", "Quark" and "QUARK"; querying the
        // uppercase prefix "QUAR" proves both case-insensitivity and substring
        // (not whole-word) matching in one shot.
        let (result, matches) = try runSearch("QUAR")

        XCTAssertEqual(result.exitCode, 0, "`om search <vault> QUAR` must exit 0")
        let list = try XCTUnwrap(matches, "`om search <vault> QUAR` must emit a JSON object with a `matches` array")

        XCTAssertEqual(
            list,
            [
                Match(path: "A Note With Spaces.md", line: 3, text: "A spaced-name note mentions quark on line three."),
                Match(path: "Alpha.md", line: 3, text: "The word quark appears on line three of Alpha."),
                Match(path: "Alpha.md", line: 5, text: "Quark appears again on line five of Alpha."),
                Match(path: "Beta.md", line: 3, text: "Beta mentions quark on line three."),
                Match(path: "Beta.md", line: 5, text: "A QUARK in uppercase appears on line five of Beta."),
                Match(path: "Notes/Nested.md", line: 3, text: "A nested note also mentions quark on line three."),
            ],
            "every case-insensitive substring match must be reported with note-relative path, one-based line and full line text"
        )
    }

    // MARK: - Criterion 2

    /// Matches are sorted ascending by `path`, then numerically by `line`.
    func testMatchesAreSortedByPathThenLine() throws {
        let (result, matches) = try runSearch("quark")

        XCTAssertEqual(result.exitCode, 0, "`om search <vault> quark` must exit 0")
        let list = try XCTUnwrap(matches, "`om search <vault> quark` must emit a JSON object with a `matches` array")

        let coordinates = list.map { "\($0.path):\($0.line)" }
        XCTAssertEqual(
            coordinates,
            [
                "A Note With Spaces.md:3",
                "Alpha.md:3",
                "Alpha.md:5",
                "Beta.md:3",
                "Beta.md:5",
                "Notes/Nested.md:3",
            ],
            "matches must be sorted ascending by path, then numerically by line"
        )
    }

    // MARK: - Criterion 3

    /// The search visits all indexed Markdown notes — top-level, nested, and
    /// with a space in the filename — and never searches non-Markdown files.
    func testSearchVisitsAllMarkdownNotesIncludingNestedAndSpacedNamesButNotNonMarkdown() throws {
        // Prove the non-Markdown fixtures really contain the query term, so
        // their absence from the results is meaningful rather than vacuous.
        let txt = try String(contentsOf: vaultURL.appendingPathComponent("notes.txt"), encoding: .utf8)
        let png = try String(contentsOf: vaultURL.appendingPathComponent("image.png"), encoding: .utf8)
        XCTAssertTrue(txt.localizedCaseInsensitiveContains("quark"), "the fixture text file must contain the query term")
        XCTAssertTrue(png.localizedCaseInsensitiveContains("quark"), "the fixture image file must contain the query term")

        let (result, matches) = try runSearch("quark")
        XCTAssertEqual(result.exitCode, 0, "`om search <vault> quark` must exit 0")
        let list = try XCTUnwrap(matches, "`om search <vault> quark` must emit a JSON object with a `matches` array")

        let matchedPaths = Set(list.map(\.path))
        XCTAssertEqual(
            matchedPaths,
            Set(["A Note With Spaces.md", "Alpha.md", "Beta.md", "Notes/Nested.md"]),
            "the search must visit every indexed Markdown note — top-level, nested, and with a space in the filename"
        )
        XCTAssertFalse(
            matchedPaths.contains { ($0 as NSString).pathExtension.lowercased() != "md" },
            "no non-Markdown file may appear in the search results"
        )
    }

    // MARK: - Criterion 4

    /// A search that finds nothing is still a successful search: it emits valid
    /// JSON with an empty `matches` array and exits 0.
    func testSearchWithNoMatchesEmitsValidJsonAndExitsZero() throws {
        let (result, matches) = try runSearch("zzyzx")

        XCTAssertEqual(result.exitCode, 0, "a search with no matches must still exit 0")
        let list = try XCTUnwrap(matches, "a search with no matches must still emit a JSON object with a `matches` array")
        XCTAssertEqual(list, [], "a search with no matches must emit an empty `matches` array")
    }

    /// A processing error — here, a vault path that does not exist — exits
    /// nonzero and reports a message on stderr.
    func testSearchOnInvalidVaultExitsNonzeroAndReportsOnStderr() throws {
        let result = try runOm(["search", "/nonexistent/definitely/not/a/vault", "quark"])

        XCTAssertNotEqual(result.exitCode, 0, "`om search` on an invalid vault must exit nonzero")
        XCTAssertFalse(result.stderr.isEmpty, "`om search` on an invalid vault must report the error on stderr")
    }
}
