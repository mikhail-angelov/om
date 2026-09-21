import Foundation
import XCTest

/// Acceptance tests for the VA-002 slice: `om links <vault>`.
///
/// The use case is "Inspect resolved and broken links in a vault": a user or
/// local tool runs `om links <vault>` and receives JSON separating valid
/// wikilinks from broken targets, with resolved note paths and any anchor or
/// alias preserved as structured data.
///
/// These tests drive the `om` executable as a subprocess — the same boundary a
/// user or local tool actually crosses — and assert the JSON it writes to
/// stdout, its exit status, and its error reporting on stderr. The current
/// checkout implements only `om index`, so every link test here fails until
/// the VA-002 behavior exists.
final class OmVaultLinksAcceptanceTests: XCTestCase {

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

    /// The fixture vault used by the link tests. It lives in the source tree
    /// (allowed under `Tests/**/Resources/**`) and is located relative to this
    /// file, so no bundle-resource declaration in `Package.swift` is needed.
    private var vaultURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/LinksVault")
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

    /// Runs `om links <vault>` and returns the process result together with the
    /// parsed output. When the exit code is nonzero the parsed output is `nil`,
    /// because a failed run may not have written JSON to stdout at all.
    private func runLinks() throws -> (result: RunResult, output: [String: Any]?) {
        let result = try runOm(["links", vaultURL.path])
        guard result.exitCode == 0 else { return (result, nil) }

        let object = try JSONSerialization.jsonObject(with: result.stdout, options: [])
        let root = try XCTUnwrap(object as? [String: Any], "Expected a JSON object, got \(object)")
        _ = try XCTUnwrap(root["links"] as? [[String: Any]], "Expected a `links` array, got \(root)")
        _ = try XCTUnwrap(root["broken"] as? [[String: Any]], "Expected a `broken` array, got \(root)")
        return (result, root)
    }

    /// Convenience: the parsed `links` and `broken` arrays of a successful run.
    private func linksAndBroken() throws -> (links: [[String: Any]], broken: [[String: Any]]) {
        let (_, output) = try runLinks()
        let root = try XCTUnwrap(output, "`om links` must exit 0 and emit JSON")
        return (
            links: try XCTUnwrap(root["links"] as? [[String: Any]]),
            broken: try XCTUnwrap(root["broken"] as? [[String: Any]])
        )
    }

    // MARK: - Criterion 1

    /// The four wikilink shapes — `[[Target]]`, `[[Target|alias]]`,
    /// `[[Target#Anchor]]`, `[[Target#Anchor|alias]]` — are all recognized, and
    /// `anchor`/`alias` are emitted only on the shapes that carry them.
    func testLinksRecognizeAllFourFormsWithAnchorAndAliasOnlyWhenPresent() throws {
        let (links, _) = try linksAndBroken()
        let fromForms = links.filter { ($0["from"] as? String) == "Forms.md" }

        // Every shape is written exactly once, so each filter below must match
        // exactly one entry. This also proves no shape is dropped or duplicated.
        let plain = fromForms.filter {
            ($0["target"] as? String) == "Beta" && $0["anchor"] == nil && $0["alias"] == nil
        }
        let alias = fromForms.filter {
            ($0["target"] as? String) == "Beta" && ($0["alias"] as? String) == "друг" && $0["anchor"] == nil
        }
        let anchor = fromForms.filter {
            ($0["target"] as? String) == "Beta" && ($0["anchor"] as? String) == "Раздел" && $0["alias"] == nil
        }
        let anchorAndAlias = fromForms.filter {
            ($0["target"] as? String) == "Beta" && ($0["anchor"] as? String) == "Раздел" && ($0["alias"] as? String) == "оба сразу"
        }

        XCTAssertEqual(fromForms.count, 4, "Forms.md must produce exactly four links")
        XCTAssertEqual(plain.count, 1, "`[[Beta]]` must produce one plain link")
        XCTAssertEqual(alias.count, 1, "`[[Beta|друг]]` must produce one aliased link")
        XCTAssertEqual(anchor.count, 1, "`[[Beta#Раздел]]` must produce one anchored link")
        XCTAssertEqual(anchorAndAlias.count, 1, "`[[Beta#Раздел|оба сразу]]` must produce one anchored+aliased link")

        XCTAssertEqual(plain.first?["resolved"] as? String, "Beta.md")
        XCTAssertNil(plain.first?["anchor"], "`[[Beta]]` must not emit `anchor`")
        XCTAssertNil(plain.first?["alias"], "`[[Beta]]` must not emit `alias`")

        XCTAssertNil(alias.first?["anchor"], "`[[Beta|друг]]` must not emit `anchor`")
        XCTAssertEqual(alias.first?["resolved"] as? String, "Beta.md")

        XCTAssertNil(anchor.first?["alias"], "`[[Beta#Раздел]]` must not emit `alias`")
        XCTAssertEqual(anchor.first?["resolved"] as? String, "Beta.md")

        XCTAssertEqual(anchorAndAlias.first?["resolved"] as? String, "Beta.md")
    }

    // MARK: - Criterion 2

    /// Targets resolve by filename without `.md`, case-insensitively and
    /// independently of subfolder; `[[Target.md]]` resolves to the same note as
    /// `[[Target]]`.
    func testLinksResolveCaseInsensitivelyAcrossSubfoldersAndWithExplicitExtension() throws {
        let (links, broken) = try linksAndBroken()
        let fromResolves = links.filter { ($0["from"] as? String) == "Resolves.md" }

        // Every one of the seven links in Resolves.md must resolve; none may be
        // reported broken (a case- or extension-sensitive resolver would drop
        // `[[beta]]`, `[[BETA]]`, `[[Beta.md]]`, `[[Deep.md]]` into `broken`).
        XCTAssertFalse(
            broken.contains { ($0["from"] as? String) == "Resolves.md" },
            "Resolves.md must not contain any broken link"
        )
        XCTAssertEqual(
            fromResolves.count, 7,
            "All seven links in Resolves.md must be reported as resolved links"
        )

        // Three written forms (`[[beta]]`, `[[BETA]]`, `[[Beta.md]]`) collapse
        // onto the single note `Beta.md`, proving case-insensitive resolution
        // and that an explicit `.md` suffix is treated like no suffix.
        let byResolved = Dictionary(grouping: fromResolves, by: { ($0["resolved"] as? String) ?? "" })
        XCTAssertEqual(
            byResolved["Beta.md"]?.count, 3,
            "lowercase, uppercase and `.md` forms must all resolve to Beta.md"
        )
        // The bare name and the explicit-extension name both resolve to the
        // note nested in a subfolder, proving resolution is independent of
        // subfolder and that `[[Deep.md]]` is the same note as `[[Deep]]`.
        XCTAssertEqual(
            byResolved["Nested/Deep.md"]?.count, 2,
            "`[[Deep]]` and `[[Deep.md]]` must resolve to the same nested note"
        )
        // A filename containing a space resolves like any other note, and a
        // case variant of that name resolves to it as well.
        XCTAssertEqual(
            byResolved["Code Samples.md"]?.count, 2,
            "`[[Code Samples]]` and `[[code samples]]` must resolve to the space-named note"
        )
    }

    // MARK: - Criterion 3

    /// A link whose target has no indexed note appears in `broken` and not in
    /// `links`; each resolved link reports a source-relative `from` and a
    /// target-relative `resolved` path.
    func testBrokenTargetsAreSeparateAndResolvedLinksReportRelativePaths() throws {
        let (links, broken) = try linksAndBroken()

        // `[[Ghost]]` in Broken.md has no note, so it is broken...
        let brokenFromBroken = broken.filter { ($0["from"] as? String) == "Broken.md" }
        XCTAssertEqual(brokenFromBroken.count, 1, "The one broken link in Broken.md must be reported")
        XCTAssertEqual(brokenFromBroken.first?["target"] as? String, "Ghost")
        // ...and never appears among resolved links.
        XCTAssertFalse(
            links.contains { ($0["target"] as? String) == "Ghost" },
            "A broken target must not appear in `links`"
        )

        // The valid link reports a source-relative `from` and a target-relative
        // `resolved` path.
        let validFromBroken = links.filter { ($0["from"] as? String) == "Broken.md" }
        XCTAssertEqual(validFromBroken.count, 1, "Broken.md must contain exactly one resolved link")
        XCTAssertEqual(validFromBroken.first?["target"] as? String, "Deep")
        XCTAssertEqual(validFromBroken.first?["resolved"] as? String, "Nested/Deep.md")
        XCTAssertFalse(
            (validFromBroken.first?["resolved"] as? String)?.hasPrefix("/") ?? true,
            "`resolved` must be relative to the vault root"
        )

        // A note nested in a subfolder that links out reports a relative `from`
        // path of its own.
        let nestedSource = links.filter { ($0["from"] as? String) == "Nested/Deep.md" }
        XCTAssertEqual(nestedSource.count, 1, "Nested/Deep.md must report its link to Beta")
        XCTAssertEqual(nestedSource.first?["target"] as? String, "Beta")
        XCTAssertEqual(nestedSource.first?["resolved"] as? String, "Beta.md")
        XCTAssertFalse(
            (nestedSource.first?["from"] as? String)?.hasPrefix("/") ?? true,
            "`from` must be relative to the vault root"
        )
    }

    // MARK: - Criterion 4

    /// Wikilink-looking text inside backtick or tilde fences, four-space
    /// indented blocks, or single-backtick inline code appears in neither
    /// `links` nor `broken`.
    func testWikilinksInsideCodeAreNotReported() throws {
        let (links, broken) = try linksAndBroken()

        // CodeBlocks.md has exactly one real link (`[[Beta]]`); the four
        // code-only targets must never leak out of their code regions.
        let fromCode = links.filter { ($0["from"] as? String) == "CodeBlocks.md" }
        XCTAssertEqual(fromCode.count, 1, "CodeBlocks.md must report only its real link")
        XCTAssertEqual(fromCode.first?["target"] as? String, "Beta")
        XCTAssertEqual(fromCode.first?["resolved"] as? String, "Beta.md")

        let codeOnlyTargets = ["InlineOnly", "FenceOnly", "TildeOnly", "IndentOnly"]
        for target in codeOnlyTargets {
            XCTAssertFalse(
                links.contains { ($0["target"] as? String) == target },
                "`\(target)` inside code must not appear in `links`"
            )
            XCTAssertFalse(
                broken.contains { ($0["target"] as? String) == target },
                "`\(target)` inside code must not appear in `broken`"
            )
        }
        XCTAssertFalse(
            broken.contains { ($0["from"] as? String) == "CodeBlocks.md" },
            "CodeBlocks.md must produce no broken links"
        )
    }

    // MARK: - Criterion 5

    /// A successful `om links` writes valid JSON to stdout and exits 0.
    func testLinksWritesValidJsonToStdoutAndExitsZero() throws {
        let (result, output) = try runLinks()

        XCTAssertEqual(result.exitCode, 0, "`om links <vault>` must exit 0 on success")
        let root = try XCTUnwrap(output, "stdout must be a JSON object with `links` and `broken` arrays")
        let links = try XCTUnwrap(root["links"] as? [[String: Any]])
        let broken = try XCTUnwrap(root["broken"] as? [[String: Any]])
        XCTAssertFalse(links.isEmpty, "The fixture vault has links, so `links` must not be empty")
        XCTAssertFalse(broken.isEmpty, "The fixture vault has a broken target, so `broken` must not be empty")
    }

    /// A processing error (an invalid vault) makes `om links` exit nonzero and
    /// report a message on stderr.
    func testLinksOnInvalidVaultExitsNonzeroAndReportsOnStderr() throws {
        let result = try runOm(["links", "/nonexistent/definitely/not/a/vault"])

        XCTAssertNotEqual(result.exitCode, 0, "`om links` on an invalid vault must exit nonzero")
        XCTAssertFalse(result.stderr.isEmpty, "`om links` on an invalid vault must report an error on stderr")
    }
}
