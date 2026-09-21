import Foundation
import OmVault
import XCTest

/// Acceptance tests for the VA-007 slice: navigate from an editor wikilink to
/// its target note.
///
/// The use case is "Navigate from an editor wikilink to its target note": a
/// macOS user activates a `[[...]]` link while editing or previewing a note,
/// and the editor resolves it through OmVault and opens the matching target
/// note in the existing session.
///
/// The activation itself is a SwiftUI interaction. A SwiftPM test target has no
/// UI-automation runner to drive it, so the open/select behaviors (criteria 1-3)
/// are recorded as uncovered in the accompanying report. What *is* decidable
/// headlessly — and is red against the current checkout — is the integration
/// contract criterion 4 is written about: the editor's navigation must call the
/// existing OmVault note-resolution API (`VaultLinkInspector`) rather than
/// reimplementing resolution, and OmVault itself must keep its behavior. The
/// current `Sources/OmEditor` files reference `VaultIndexer` (to open a vault)
/// but never `VaultLinkInspector` (to resolve a link), so the delegation test
/// fails until VA-007 is implemented.
final class OmVaultEditorNavigationAcceptanceTests: XCTestCase {

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

    /// Every Swift source file directly under `Sources/OmEditor`.
    private func omEditorSourceFiles() throws -> [URL] {
        let dir = packageRoot.appendingPathComponent("Sources/OmEditor")
        return try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { ($0 as NSString).pathExtension == "swift" }
            .map { dir.appendingPathComponent($0) }
    }

    /// Every Swift source file directly under `Sources/OmVault`.
    private func omVaultSourceFiles() throws -> [URL] {
        let dir = packageRoot.appendingPathComponent("Sources/OmVault")
        return try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { ($0 as NSString).pathExtension == "swift" }
            .map { dir.appendingPathComponent($0) }
    }

    // MARK: - Criterion 4

    /// Editor navigation must call the existing OmVault note-resolution API
    /// (`VaultLinkInspector`) instead of reimplementing link resolution. The
    /// reference is asserted on the OmEditor sources: a target dependency on
    /// OmVault is already satisfied by `openVault`, so only a direct reference
    /// to the resolver proves navigation delegates resolution to the engine.
    func testEditorNavigationDelegatesToOmVaultLinkResolution() throws {
        let files = try omEditorSourceFiles()
        XCTAssertFalse(files.isEmpty, "the OmEditor sources must be present")

        let referencing = files.filter { file in
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else {
                return false
            }
            return contents.contains("VaultLinkInspector")
        }

        XCTAssertFalse(
            referencing.isEmpty,
            "editor navigation must call the existing OmVault note-resolution API (VaultLinkInspector) instead of reimplementing link resolution"
        )
    }

    /// The slice makes no behavior change to OmVault: its sources import
    /// neither the editor's UI frameworks nor the MarkdownEngine product and
    /// carry no SwiftUI state machinery or app entry point.
    func testOmVaultSourcesCarryNoEditorNavigationResponsibilities() throws {
        let files = try omVaultSourceFiles()
        XCTAssertFalse(files.isEmpty, "the OmVault sources must be present")

        let forbiddenImports = ["import SwiftUI", "import AppKit", "import MarkdownEngine"]
        let forbiddenMarkers = [
            "ObservableObject", "@Published", "@StateObject", "@EnvironmentObject", "@main",
        ]

        for file in files {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for marker in forbiddenImports {
                XCTAssertFalse(
                    contents.contains(marker),
                    "\(file.lastPathComponent) must not import \(marker)"
                )
            }
            for marker in forbiddenMarkers {
                XCTAssertFalse(
                    contents.contains(marker),
                    "\(file.lastPathComponent) must not carry \(marker)"
                )
            }
        }
    }

    /// The existing OmVault note-resolution API keeps the behavior navigation
    /// depends on: target names resolve case-insensitively, an explicit `.md`
    /// suffix is accepted, notes in nested folders resolve, and a link's anchor
    /// and alias are kept separate from the target used for resolution.
    func testOmVaultLinkResolutionBehaviorIsUnchanged() throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        let nested = vault.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("# Target\n".utf8).write(to: nested.appendingPathComponent("Target.md"))
        try Data(
            """
            [[target]] [[TARGET]] [[Target.md]] [[Target#Anchor|alias]]
            """.utf8
        ).write(to: vault.appendingPathComponent("Source.md"))

        let report = try VaultLinkInspector().inspect(vaultAt: vault)

        XCTAssertTrue(report.broken.isEmpty, "every written form must resolve")
        XCTAssertEqual(
            report.links.count, 4,
            "the four written forms must all be reported as resolved links"
        )

        for link in report.links {
            XCTAssertEqual(
                link.resolved, "Nested/Target.md",
                "`\(link.target)` must resolve case-insensitively, with an optional `.md` suffix, to the nested note"
            )
        }

        let anchored = report.links.first { $0.anchor != nil || $0.alias != nil }
        XCTAssertEqual(anchored?.target, "Target")
        XCTAssertEqual(anchored?.anchor, "Anchor")
        XCTAssertEqual(anchored?.alias, "alias")
    }
}
