import Foundation
import XCTest

/// Acceptance tests for the VA-004 slice: `om rename <vault> <old name> <new name>`.
///
/// The use case is "Rename a note while preserving all valid references": a
/// user reorganizing a vault runs `om rename <vault> <old> <new>`, and every
/// real link that resolved to the old note must be rewritten to the new name —
/// across all vault notes, including the renamed note itself — while link
/// decorations (alias, anchor, `.md` suffix), code spans, broken links and
/// unrelated files stay exactly as they were.
///
/// These tests drive the `om` executable as a subprocess — the same boundary a
/// user or local tool actually crosses — and assert the JSON it writes to
/// stdout, its exit status, its stderr on failure, and the bytes left on disk.
/// The fixture vault is copied to a temporary directory before each test so a
/// rename can mutate files without touching the read-only source resources.
/// The current checkout implements only `om index`, `om links` and
/// `om backlinks`; `om rename` is not wired up, so every rename test here fails
/// until the VA-004 behavior exists.
final class OmVaultRenameAcceptanceTests: XCTestCase {

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

    /// The fixture vault used by the rename tests. It lives in the source tree
    /// (allowed under `Tests/**/Resources/**`) and is located relative to this
    /// file, so no bundle-resource declaration in `Package.swift` is needed.
    private var vaultURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/RenameVault")
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

    /// Copies the read-only fixture vault to a fresh temporary directory so a
    /// rename can mutate files without touching the source tree.
    private func makeVaultCopy() throws -> URL {
        let fm = FileManager.default
        let copy = fm.temporaryDirectory
            .appendingPathComponent("RenameVault-\(UUID().uuidString)", isDirectory: true)
        try fm.copyItem(at: vaultURL, to: copy)
        addTeardownBlock { try? fm.removeItem(at: copy) }
        return copy
    }

    /// Snapshots every regular file under the vault as relative path -> bytes,
    /// so tests can assert byte-for-byte stability.
    private func snapshotFiles(in vault: URL) throws -> [String: Data] {
        let fm = FileManager.default
        var snapshot: [String: Data] = [:]
        guard let enumerator = fm.enumerator(atPath: vault.path) else { return snapshot }
        for case let path as String in enumerator {
            let full = vault.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: full.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }
            snapshot[path] = try Data(contentsOf: full)
        }
        return snapshot
    }

    private func readText(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Rename report parsing

    private struct RenameReport {
        let from: String
        let to: String
        let updated: [[String: Any]]
        let skipped: [Any]
    }

    /// Parses the single JSON document a successful `om rename` writes to
    /// stdout. `JSONSerialization` rejects trailing garbage, so a successful
    /// parse also proves stdout carries exactly one valid JSON document.
    private func parseRenameReport(_ data: Data) throws -> RenameReport {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        let root = try XCTUnwrap(object as? [String: Any], "rename stdout must be a JSON object, got \(object)")
        let renamed = try XCTUnwrap(root["renamed"] as? [String: Any], "expected a `renamed` object, got \(root)")
        let from = try XCTUnwrap(renamed["from"] as? String, "expected a `renamed.from` string, got \(renamed)")
        let to = try XCTUnwrap(renamed["to"] as? String, "expected a `renamed.to` string, got \(renamed)")
        let updated = try XCTUnwrap(root["updated"] as? [[String: Any]], "expected an `updated` array, got \(root)")
        let skipped = try XCTUnwrap(root["skipped"] as? [Any], "expected a `skipped` array, got \(root)")
        return RenameReport(from: from, to: to, updated: updated, skipped: skipped)
    }

    /// Runs `om rename` and returns the process result together with the parsed
    /// report. When the exit code is nonzero the report is `nil`, because a
    /// failed run may not have written JSON to stdout at all.
    private func runRename(
        _ vault: URL,
        from oldName: String,
        to newName: String
    ) throws -> (result: RunResult, report: RenameReport?) {
        let result = try runOm(["rename", vault.path, oldName, newName])
        guard result.exitCode == 0 else { return (result, nil) }
        return (result, try parseRenameReport(result.stdout))
    }

    // MARK: - Links report parsing

    private struct LinksReport {
        let links: [[String: Any]]
        let broken: [[String: Any]]
    }

    private func runLinks(_ vault: URL) throws -> (result: RunResult, report: LinksReport?) {
        let result = try runOm(["links", vault.path])
        guard result.exitCode == 0 else { return (result, nil) }
        let object = try JSONSerialization.jsonObject(with: result.stdout, options: [])
        let root = try XCTUnwrap(object as? [String: Any], "`om links` stdout must be a JSON object, got \(object)")
        let links = try XCTUnwrap(root["links"] as? [[String: Any]], "expected a `links` array, got \(root)")
        let broken = try XCTUnwrap(root["broken"] as? [[String: Any]], "expected a `broken` array, got \(root)")
        return (result, LinksReport(links: links, broken: broken))
    }

    // MARK: - Criterion 1

    /// Renaming a uniquely resolved note changes its filename but keeps its
    /// folder, exits 0, and reports `renamed.from`, `renamed.to`, `updated` and
    /// `skipped` — the last being an empty array when every update succeeds.
    func testRenameChangesFilenameAndReportsJsonWithEmptySkipped() throws {
        let vault = try makeVaultCopy()

        let (result, report) = try runRename(vault, from: "Beta", to: "Delta")

        XCTAssertEqual(result.exitCode, 0, "`om rename` onto a free name must exit 0")
        let r = try XCTUnwrap(report, "a successful rename must write a JSON report to stdout")
        XCTAssertEqual(r.from, "Beta.md", "`renamed.from` must be the old relative path")
        XCTAssertEqual(r.to, "Delta.md", "`renamed.to` must be the new relative path")
        XCTAssertEqual(r.skipped.count, 0, "when every update succeeds, `skipped` must be an empty array")

        let fm = FileManager.default
        XCTAssertFalse(
            fm.fileExists(atPath: vault.appendingPathComponent("Beta.md").path),
            "the old note file must be gone after the rename"
        )
        XCTAssertTrue(
            fm.fileExists(atPath: vault.appendingPathComponent("Delta.md").path),
            "the new note file must exist after the rename"
        )
    }

    /// Renaming a note nested in a subfolder keeps it in that subfolder: both
    /// sides of `renamed` keep the `Nested/` prefix.
    func testRenamePreservesContainingFolderOfNestedNote() throws {
        let vault = try makeVaultCopy()

        let (result, report) = try runRename(vault, from: "Deep", to: "Deeper")

        XCTAssertEqual(result.exitCode, 0, "renaming a nested note must exit 0")
        let r = try XCTUnwrap(report, "a successful rename must write a JSON report to stdout")
        XCTAssertEqual(r.from, "Nested/Deep.md", "`renamed.from` must keep the containing folder")
        XCTAssertEqual(r.to, "Nested/Deeper.md", "`renamed.to` must keep the containing folder")

        let fm = FileManager.default
        XCTAssertFalse(
            fm.fileExists(atPath: vault.appendingPathComponent("Nested/Deep.md").path),
            "the old nested note must be gone"
        )
        XCTAssertTrue(
            fm.fileExists(atPath: vault.appendingPathComponent("Nested/Deeper.md").path),
            "the renamed note must stay inside its containing folder"
        )
    }

    // MARK: - Criterion 2

    /// Every link that resolved to the old note is rewritten in every vault
    /// note (top-level, nested, spaced-name, and the renamed note itself);
    /// aliases and anchors stay byte-for-byte intact and a target written with
    /// `.md` keeps its extension.
    func testRenameUpdatesEveryResolvedLinkPreservingAliasAnchorAndExtension() throws {
        let vault = try makeVaultCopy()

        let (result, _) = try runRename(vault, from: "Beta", to: "Delta")
        guard result.exitCode == 0 else {
            XCTFail("`om rename` onto a free name must exit 0")
            return
        }

        let alpha = try readText(vault.appendingPathComponent("Alpha.md"))
        XCTAssertTrue(alpha.contains("- plain: [[Delta]]"), "the plain link must be rewritten to the new name")
        XCTAssertTrue(alpha.contains("[[Delta|друг]]"), "the alias after `|` must survive byte-for-byte")
        XCTAssertTrue(alpha.contains("[[Delta#Раздел]]"), "the anchor after `#` must survive byte-for-byte")
        XCTAssertTrue(alpha.contains("[[Delta#Раздел|оба сразу]]"), "anchor and alias together must survive")
        XCTAssertTrue(alpha.contains("[[Delta.md]]"), "a target written with `.md` must keep its extension")
        XCTAssertTrue(alpha.contains("- lowercase spelling: [[Delta]]"), "a case-insensitive spelling must be rewritten to the new name")

        // The renamed note's own self-references are updated too.
        let delta = try readText(vault.appendingPathComponent("Delta.md"))
        XCTAssertTrue(delta.contains("Beta refers to itself: [[Delta]]"), "the renamed note's self-reference must be updated")
        XCTAssertTrue(delta.contains("[[Delta|сама]]"), "the renamed note's aliased self-reference must keep its alias")
        XCTAssertTrue(delta.contains("Beta also links to [[Gamma]], a different note."), "links to other notes must not change")

        // All other vault notes that linked to Beta are updated as well.
        XCTAssertTrue(
            try readText(vault.appendingPathComponent("Nested/Deep.md")).contains("A nested note links to Beta by name: [[Delta]]"),
            "nested notes must be updated"
        )
        XCTAssertTrue(
            try readText(vault.appendingPathComponent("Code Samples.md")).contains("A real link: [[Delta]]"),
            "notes whose name contains a space must be updated"
        )
        XCTAssertTrue(
            try readText(vault.appendingPathComponent("Broken.md")).contains("A valid target: [[Delta]]"),
            "a valid link must be rewritten"
        )
    }

    // MARK: - Criterion 3

    /// Wikilink-looking text inside inline, fenced and four-space-indented code
    /// stays unchanged, and a link that was already broken before the rename
    /// stays unchanged.
    func testRenameLeavesCodeSpansAndBrokenLinksUntouched() throws {
        let vault = try makeVaultCopy()

        let (result, _) = try runRename(vault, from: "Beta", to: "Delta")
        guard result.exitCode == 0 else {
            XCTFail("`om rename` onto a free name must exit 0")
            return
        }

        let alpha = try readText(vault.appendingPathComponent("Alpha.md"))
        XCTAssertTrue(alpha.contains("`[[Beta]]`"), "inline code must not be rewritten")
        XCTAssertTrue(
            alpha.contains("A fenced block is verbatim text, not a link:\n[[Beta]]\n[[Beta|друг]]"),
            "fenced code must not be rewritten"
        )
        XCTAssertTrue(
            alpha.contains("    An indented code block is verbatim too:\n    [[Beta]]"),
            "four-space-indented code must not be rewritten"
        )
        XCTAssertTrue(alpha.contains("[[Ghost]]"), "a broken link must not be rewritten")

        let samples = try readText(vault.appendingPathComponent("Code Samples.md"))
        XCTAssertTrue(samples.contains("`[[Beta]]`"), "inline code must not be rewritten")
        XCTAssertTrue(samples.contains("// inside a fence: [[Beta]]"), "a backtick-fenced block must not be rewritten")
        XCTAssertTrue(samples.contains("a tilde fence: [[Beta]]"), "a tilde-fenced block must not be rewritten")
        XCTAssertTrue(samples.contains("    an indented block: [[Beta]]"), "an indented block must not be rewritten")

        let broken = try readText(vault.appendingPathComponent("Broken.md"))
        XCTAssertTrue(broken.contains("A broken target: [[Ghost]]"), "a broken target must remain unchanged")
    }

    // MARK: - Criterion 4

    /// `updated` is sorted by relative path and lists only files whose bytes
    /// actually changed, with `links` equal to the number of replacements in
    /// that file; files with nothing to replace stay byte-for-byte unchanged
    /// and never appear in `updated`.
    func testUpdatedListsOnlyChangedFilesSortedWithCorrectLinkCounts() throws {
        let vault = try makeVaultCopy()
        let before = try snapshotFiles(in: vault)

        let (result, report) = try runRename(vault, from: "Beta", to: "Delta")
        XCTAssertEqual(result.exitCode, 0, "`om rename` onto a free name must exit 0")
        let r = try XCTUnwrap(report, "a successful rename must write a JSON report to stdout")

        let paths = r.updated.map { ($0["path"] as? String) ?? "" }
        XCTAssertEqual(paths, paths.sorted(), "`updated` must be sorted by relative path")

        let linksByPath: [String: Int] = r.updated.reduce(into: [:]) { result, entry in
            result[entry["path"] as? String ?? ""] = (entry["links"] as? NSNumber)?.intValue ?? -1
        }

        // The four unchanged-by-design files carry exact, known replacement
        // counts (Alpha.md has six real links to Beta).
        XCTAssertEqual(linksByPath["Alpha.md"], 6, "Alpha.md holds six links to the renamed note")
        XCTAssertEqual(linksByPath["Broken.md"], 1, "Broken.md holds one valid link to the renamed note")
        XCTAssertEqual(linksByPath["Code Samples.md"], 1, "Code Samples.md holds one real link to the renamed note")
        XCTAssertEqual(linksByPath["Nested/Deep.md"], 1, "Nested/Deep.md holds one link to the renamed note")

        // The renamed note itself is also updated (two self-links). Its path is
        // reported either as the old or the new filename; the spec only fixes
        // "sorted by path" and "links == number of replacements", not which of
        // the two names the renamed note is listed under.
        let renamedEntry = r.updated.first {
            ($0["path"] as? String) == "Beta.md" || ($0["path"] as? String) == "Delta.md"
        }
        XCTAssertNotNil(renamedEntry, "the renamed note's self-link update must be reported")
        XCTAssertEqual((renamedEntry?["links"] as? NSNumber)?.intValue, 2, "the renamed note holds two self-links")

        // No unchanged file may appear; the two notes with nothing to replace
        // must stay byte-for-byte identical and out of `updated`.
        XCTAssertNil(linksByPath["Untouched.md"], "a note with nothing to change must not appear in `updated`")
        XCTAssertNil(linksByPath["Gamma.md"], "an unrelated note must not appear in `updated`")
        XCTAssertEqual(
            try Data(contentsOf: vault.appendingPathComponent("Untouched.md")),
            before["Untouched.md"],
            "a note with no replacement must remain byte-for-byte unchanged"
        )
        XCTAssertEqual(
            try Data(contentsOf: vault.appendingPathComponent("Gamma.md")),
            before["Gamma.md"],
            "an unrelated note must remain byte-for-byte unchanged"
        )
    }

    // MARK: - Criterion 5

    /// Running link analysis after a successful rename introduces no new broken
    /// link for a reference that previously resolved to the renamed note.
    func testRenameIntroducesNoNewBrokenLinks() throws {
        let vault = try makeVaultCopy()

        let (beforeResult, beforeReport) = try runLinks(vault)
        XCTAssertEqual(beforeResult.exitCode, 0, "`om links` before the rename must exit 0")
        let before = try XCTUnwrap(beforeReport)
        let beforeBroken = Set(before.broken.compactMap { ($0["target"] as? String)?.lowercased() })
        XCTAssertEqual(beforeBroken, ["ghost"], "the fixture vault starts with exactly one broken target")

        let (renameResult, _) = try runRename(vault, from: "Beta", to: "Delta")
        XCTAssertEqual(renameResult.exitCode, 0, "`om rename` onto a free name must exit 0")

        let (afterResult, afterReport) = try runLinks(vault)
        XCTAssertEqual(afterResult.exitCode, 0, "`om links` after the rename must exit 0")
        let after = try XCTUnwrap(afterReport)
        let afterBroken = Set(after.broken.compactMap { ($0["target"] as? String)?.lowercased() })

        XCTAssertEqual(afterBroken, beforeBroken, "the rename must introduce no new broken link")
        XCTAssertFalse(afterBroken.contains("beta"), "no reference to the old name may be left broken")
        XCTAssertFalse(afterBroken.contains("delta"), "no reference to the new name may be broken")
        XCTAssertTrue(
            after.links.contains { ($0["resolved"] as? String) == "Delta.md" },
            "references that resolved to the renamed note must now resolve to the new note"
        )
    }

    // MARK: - Criterion 6

    /// Renaming onto a name that is already occupied exits nonzero, reports an
    /// error on stderr, and leaves every file byte-for-byte unchanged. A
    /// control rename to a free name in the same vault proves the failure is
    /// about the occupied destination, not a missing rename feature.
    func testRenameOntoOccupiedNameFailsAndLeavesVaultUnchanged() throws {
        let vault = try makeVaultCopy()
        let before = try snapshotFiles(in: vault)

        let occupied = try runOm(["rename", vault.path, "Beta", "Gamma"])
        XCTAssertNotEqual(occupied.exitCode, 0, "renaming onto an occupied name must exit nonzero")
        XCTAssertFalse(occupied.stderr.isEmpty, "renaming onto an occupied name must report an error on stderr")
        XCTAssertEqual(
            try snapshotFiles(in: vault),
            before,
            "the failed rename must leave every file byte-for-byte unchanged"
        )

        // Control: the same vault can still be renamed to a free name, so the
        // occupied-name failure is about the destination, not a missing rename.
        let control = try runOm(["rename", vault.path, "Beta", "Delta"])
        XCTAssertEqual(control.exitCode, 0, "a rename to a free name in the same vault must still succeed")
    }
}
