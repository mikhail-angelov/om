import Foundation
import OmVault
import XCTest

/// Acceptance tests for the VA-006 slice: the macOS editor host that opens a
/// vault and edits a note with live preview.
///
/// The slice is a SwiftUI editor layered on the completed OmVault note-index
/// API and the external `MarkdownEngine` product. A SwiftPM test target cannot
/// drive SwiftUI — there is no UI-automation runner for an executable target —
/// so the display/render/save interactions themselves (criteria 1-3) are
/// recorded as uncovered in the accompanying report. What *is* decidable from
/// a headless test is the package-level contract the slice must satisfy: the
/// manifest declares exactly the permitted dependency and keeps OmVault and the
/// `om` CLI dependency-free (criterion 4), and the editor target consumes the
/// OmVault library while the engine itself is left untouched (criterion 5).
/// Those contracts are asserted here against the current checkout, where no
/// editor target or MarkdownEngine dependency exists yet, so the manifest tests
/// fail until VA-006 is implemented.
final class OmEditorAcceptanceTests: XCTestCase {

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

    /// The fixture vault used to verify the note-index interface still behaves
    /// as VA-001 established. It lives under `Tests/**/Resources/**` and holds
    /// top-level, nested and space-named notes plus non-Markdown files.
    private var indexVaultURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/IndexVault")
    }

    // MARK: - Manifest inspection helpers

    private struct TargetDeclaration {
        let name: String
        let body: String
    }

    /// The raw text of `Package.swift`. The manifest is the artifact criterion
    /// 4 is written about, so reading it (rather than re-implementing it) is
    /// the smallest boundary that decides that criterion.
    private func packageManifest() throws -> String {
        try String(
            contentsOf: packageRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
    }

    /// Extracts every `.target`, `.executableTarget` and `.testTarget`
    /// declaration together with its balanced-parenthesis body, so assertions
    /// about target dependencies do not depend on how the manifest is wrapped.
    private func targetDeclarations(in manifest: String) -> [TargetDeclaration] {
        let kinds = [".target(", ".executableTarget(", ".testTarget("]
        let ns = manifest as NSString
        var results: [TargetDeclaration] = []
        for kind in kinds {
            var searchFrom = 0
            while searchFrom < ns.length {
                let found = ns.range(
                    of: kind,
                    options: [],
                    range: NSRange(location: searchFrom, length: ns.length - searchFrom)
                )
                guard found.location != NSNotFound else { break }
                let openParen = found.location + kind.count - 1
                guard let close = balancedCloseParen(in: manifest, openParen: openParen) else { break }
                let body = ns.substring(
                    with: NSRange(location: found.location, length: close - found.location + 1)
                )
                results.append(TargetDeclaration(name: targetName(in: body) ?? "", body: body))
                searchFrom = close + 1
            }
        }
        return results
    }

    /// Returns the index of the `)` that balances the `(` at `openParen`.
    private func balancedCloseParen(in text: String, openParen: Int) -> Int? {
        let chars = Array(text)
        var depth = 0
        var index = openParen
        while index < chars.count {
            if chars[index] == "(" { depth += 1 }
            else if chars[index] == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    /// The target name captured from a `name: "..."` declaration.
    private func targetName(in body: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "name:\\s*\"([^\"]+)\""),
              let match = regex.firstMatch(
                  in: body,
                  range: NSRange(location: 0, length: (body as NSString).length)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: body) else { return nil }
        return String(body[range])
    }

    /// Every external package URL declared in the manifest (`url: "..."`).
    private func externalPackageURLs(in manifest: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: "url:\\s*\"([^\"]+)\"")
        let ns = manifest as NSString
        return regex
            .matches(in: manifest, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    // MARK: - Criterion 4

    /// `Package.swift` must target macOS 14 with Swift tools 6.0, declare the
    /// `swift-markdown-engine` package/product as its only external dependency
    /// for the editor, and leave `OmVault` and the `om` CLI free of external
    /// dependencies.
    func testPackageTargetsMacOS14WithTools60AndOnlySwiftMarkdownEngineForEditor() throws {
        let manifest = try packageManifest()

        XCTAssertTrue(
            manifest.contains("swift-tools-version: 6.0"),
            "Package.swift must use Swift tools version 6.0"
        )
        XCTAssertTrue(
            manifest.contains(".macOS(.v14)"),
            "Package.swift must target macOS 14"
        )

        let urls = try externalPackageURLs(in: manifest)
        XCTAssertEqual(
            urls,
            ["https://github.com/nodes-app/swift-markdown-engine"],
            "swift-markdown-engine must be the only external package declared"
        )
        XCTAssertTrue(
            manifest.contains("MarkdownEngine"),
            "the manifest must declare the MarkdownEngine product"
        )

        let targets = targetDeclarations(in: manifest)

        // The editor is the only consumer of the MarkdownEngine product.
        let markdownEngineTargets = targets.filter { $0.body.contains("MarkdownEngine") }
        XCTAssertFalse(
            markdownEngineTargets.isEmpty,
            "some editor target must consume the MarkdownEngine product"
        )
        XCTAssertFalse(
            markdownEngineTargets.contains { $0.name == "OmVault" || $0.name == "om" },
            "OmVault and the om CLI must not depend on MarkdownEngine"
        )

        // OmVault and the om CLI stay free of any external dependency.
        for name in ["OmVault", "om"] {
            let declaration = targets.first { $0.name == name }
            let target = try XCTUnwrap(
                declaration,
                "the \(name) target must be declared in Package.swift"
            )
            XCTAssertFalse(
                target.body.contains("MarkdownEngine") || target.body.contains(".product("),
                "the \(name) target must remain free of external dependencies"
            )
        }
    }

    // MARK: - Criterion 5

    /// The editor target depends on the OmVault library, so it consumes the
    /// completed note-index interface instead of reimplementing indexing.
    func testEditorTargetConsumesTheOmVaultIndexLibrary() throws {
        let manifest = try packageManifest()
        let targets = targetDeclarations(in: manifest)

        let editorTargets = targets.filter { $0.body.contains("MarkdownEngine") }
        let editor = try XCTUnwrap(
            editorTargets.first,
            "an editor target consuming MarkdownEngine must be declared"
        )
        XCTAssertTrue(
            editor.body.contains("OmVault"),
            "the editor target must depend on the OmVault library so it uses the completed note-index interface rather than reimplementing it"
        )
    }

    /// The completed note-index interface still returns nested notes and
    /// filenames containing spaces with the same titles, and now returns the
    /// vault's other files alongside them.
    func testOmVaultNoteIndexReturnsEveryFile() throws {
        let inventory = try VaultIndexer().index(vaultAt: indexVaultURL)

        let paths = inventory.notes.map(\.path)
        XCTAssertTrue(
            paths.contains("A Note With Spaces.md"),
            "the note-index interface must still return a note whose filename contains spaces"
        )
        XCTAssertTrue(
            paths.contains("Nested/Deep.md"),
            "the note-index interface must still return a note nested in a subfolder"
        )

        let byPath = Dictionary(uniqueKeysWithValues: inventory.notes.map { ($0.path, $0) })
        XCTAssertEqual(byPath["A Note With Spaces.md"]?.title, "Spaced Out")
        XCTAssertEqual(byPath["Nested/Deep.md"]?.title, "Deep Note")

        XCTAssertTrue(
            inventory.notes.contains { ($0.path as NSString).pathExtension.lowercased() != "md" },
            "the note-index interface must return the vault's non-Markdown files too"
        )
    }

    /// OmVault keeps no editor responsibilities: its sources import neither
    /// the MarkdownEngine product nor any UI framework, and declare no SwiftUI
    /// state machinery or app entry point.
    func testOmVaultSourcesCarryNoEditorResponsibilities() throws {
        let fm = FileManager.default
        let sourcesDir = packageRoot.appendingPathComponent("Sources/OmVault")
        let files = try fm.contentsOfDirectory(atPath: sourcesDir.path)
            .filter { ($0 as NSString).pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "the OmVault sources must be present")

        let forbiddenImports = ["import SwiftUI", "import MarkdownEngine", "import UniformTypeIdentifiers"]
        let forbiddenMarkers = ["ObservableObject", "@Published", "@StateObject", "@EnvironmentObject", "@main"]

        for file in files {
            let contents = try String(
                contentsOf: sourcesDir.appendingPathComponent(file),
                encoding: .utf8
            )
            for marker in forbiddenImports {
                XCTAssertFalse(
                    contents.contains(marker),
                    "\(file) must not import editor/UI frameworks (\(marker))"
                )
            }
            for marker in forbiddenMarkers {
                XCTAssertFalse(
                    contents.contains(marker),
                    "\(file) must not carry editor responsibilities (\(marker))"
                )
            }
        }
    }
}
