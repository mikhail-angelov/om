import Foundation
import XCTest

/// Acceptance tests for the VA-001 slice: `om index <vault>`.
///
/// These tests drive the `om` executable as a subprocess — the same boundary a
/// user or local tool crosses — and assert the JSON it writes to stdout, its
/// exit status, and its error reporting on stderr. The headless `OmVault` API
/// (criterion 4) and the no-network guarantee (criterion 5) are deliberately
/// left out; the reasons are recorded in the accompanying report and, where a
/// criterion cannot be decided by any test, listed under `uncovered`.
final class OmVaultIndexAcceptanceTests: XCTestCase {

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

    /// The fixture vault used by the index tests. It lives in the source tree
    /// (allowed under `Tests/**/Resources/**`) and is located relative to this
    /// file, so no bundle-resource declaration in `Package.swift` is needed.
    private var vaultURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/IndexVault")
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
    /// exit code. Uses Foundation's `Process`/`Pipe`, which is the standard
    /// facility for driving a command-line program.
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

    private struct Note: Equatable {
        let path: String
        let name: String
        let title: String
    }

    /// Parses the single JSON document on stdout into the note inventory.
    /// `JSONSerialization` rejects trailing garbage, so a successful parse also
    /// proves that stdout carries exactly one valid JSON document.
    private func parseInventory(_ data: Data) throws -> [Note] {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        let root = try XCTUnwrap(object as? [String: Any], "Expected a JSON object, got \(object)")
        let rawNotes = try XCTUnwrap(root["notes"] as? [[String: Any]], "Expected a `notes` array, got \(root)")
        return try rawNotes.map { raw in
            Note(
                path: try XCTUnwrap(raw["path"] as? String, "Note missing string `path`: \(raw)"),
                name: try XCTUnwrap(raw["name"] as? String, "Note missing string `name`: \(raw)"),
                title: try XCTUnwrap(raw["title"] as? String, "Note missing string `title`: \(raw)")
            )
        }
    }

    /// Runs `om index <vault>` and returns the parsed inventory.
    private func indexInventory() throws -> [Note] {
        let result = try runOm(["index", vaultURL.path])
        return try parseInventory(result.stdout)
    }

    // MARK: - Criterion 1

    /// The inventory lists every file in the vault — top-level and nested,
    /// Markdown and not, including a name with spaces — and nothing hidden;
    /// each `path` is relative to the vault root and each `name` is the
    /// filename without its extension.
    func testIndexListsEveryFileWithRelativePathsAndNames() throws {
        let notes = try indexInventory()

        let expectedPaths = [
            "A Note With Spaces.md",
            "Nested/Deep.md",
            "No Heading.md",
            "README.md",
            "image.png",
            "notes.txt",
        ]
        let expectedNames = [
            "A Note With Spaces.md": "A Note With Spaces",
            "Nested/Deep.md": "Deep",
            "No Heading.md": "No Heading",
            "README.md": "README",
            "image.png": "image",
            "notes.txt": "notes",
        ]

        XCTAssertEqual(
            notes.map(\.path).sorted(),
            expectedPaths.sorted(),
            "The inventory must contain every file in the vault, relative to the vault root."
        )
        XCTAssertFalse(
            notes.contains { ($0.path as NSString).lastPathComponent.hasPrefix(".") },
            "A dotfile is the vault's own business and must never be indexed as a note"
        )

        for note in notes {
            XCTAssertFalse(
                note.path.hasPrefix("/"),
                "`path` must be relative to the vault root, got \(note.path)"
            )
            XCTAssertEqual(
                note.name,
                expectedNames[note.path],
                "`name` must be the filename without its extension, got \(note.name) for path \(note.path)"
            )
        }

        // A Markdown filename containing spaces is indexed like any other note.
        XCTAssertTrue(notes.contains { $0.path == "A Note With Spaces.md" })
    }

    // MARK: - Criterion 2

    /// `title` is the text of the first level-one heading; a note without one
    /// falls back to its `name`.
    func testIndexTitleComesFromFirstLevelOneHeadingOrName() throws {
        let notes = try indexInventory()
        let byPath = Dictionary(uniqueKeysWithValues: notes.map { ($0.path, $0) })

        XCTAssertEqual(byPath["README.md"]?.title, "Read Me")
        XCTAssertEqual(byPath["A Note With Spaces.md"]?.title, "Spaced Out")
        XCTAssertEqual(byPath["Nested/Deep.md"]?.title, "Deep Note")
        // "No Heading.md" has only a level-two heading, so its title is its name.
        XCTAssertEqual(byPath["No Heading.md"]?.title, "No Heading")
        // A file with no heading to read — plain text, or bytes that are not
        // text at all — falls back to its name the same way.
        XCTAssertEqual(byPath["notes.txt"]?.title, "notes")
        XCTAssertEqual(byPath["image.png"]?.title, "image")
    }

    // MARK: - Criterion 3

    /// A successful `om index` writes exactly one valid JSON document to stdout
    /// and exits 0.
    func testIndexWritesOneJsonDocumentAndExitsZero() throws {
        let result = try runOm(["index", vaultURL.path])

        XCTAssertEqual(result.exitCode, 0, "`om index <vault>` must exit 0 on success")

        let notes = try parseInventory(result.stdout)
        XCTAssertEqual(notes.count, 6, "A successful index of the fixture vault lists its six files")
    }

    /// An invalid vault makes `om index` exit nonzero and report the error on
    /// stderr.
    func testIndexOnInvalidVaultExitsNonzeroAndReportsOnStderr() throws {
        let result = try runOm(["index", "/nonexistent/definitely/not/a/vault"])

        XCTAssertNotEqual(
            result.exitCode, 0,
            "`om index` on an invalid vault must exit nonzero"
        )
        XCTAssertFalse(
            result.stderr.isEmpty,
            "`om index` on an invalid vault must report the error on stderr"
        )
    }
}
