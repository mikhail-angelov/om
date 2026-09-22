import Foundation
import OmVault

public enum VaultTreeItemKind: String, Codable, Sendable {
    case folder
    case note
}

public struct VaultTreeItem: Identifiable, Equatable, Sendable {
    public var id: String { "\(kind.rawValue):\(path)" }
    public let kind: VaultTreeItemKind
    public let path: String
    public let title: String
    public let modifiedAt: Date
    public let children: [VaultTreeItem]

    public init(
        kind: VaultTreeItemKind,
        path: String,
        title: String,
        modifiedAt: Date,
        children: [VaultTreeItem] = []
    ) {
        self.kind = kind
        self.path = path
        self.title = title
        self.modifiedAt = modifiedAt
        self.children = children
    }
}

public enum VaultSortField: String, Codable, Sendable {
    case name
    case modified
}

public enum VaultSortDirection: String, Codable, Sendable {
    case ascending
    case descending
}

public struct VaultSortOrder: Codable, Equatable, Sendable {
    public let field: VaultSortField
    public let direction: VaultSortDirection

    public init(field: VaultSortField, direction: VaultSortDirection) {
        self.field = field
        self.direction = direction
    }

    public static let defaultOrder = VaultSortOrder(field: .name, direction: .ascending)
}

public struct VaultTab: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var path: String
    public var title: String
    public var text: String
    public var isDirty: Bool
    public var history: [String]
    public var historyIndex: Int
}

public struct NoteProperty: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let value: String
}

public struct NoteStatus: Equatable, Sendable {
    public let words: Int
    public let characters: Int
    public let backlinks: Int
    public let properties: Int

    public static let empty = NoteStatus(words: 0, characters: 0, backlinks: 0, properties: 0)
}

public enum VaultWorkspaceError: LocalizedError, Equatable {
    case noVault
    case noActiveNote
    case unknownNote(String)
    case occupied(String)
    case invalidName(String)
    case unresolvedLink(String)

    public var errorDescription: String? {
        switch self {
        case .noVault: "Open a vault first."
        case .noActiveNote: "Select a note first."
        case .unknownNote(let path): "Unknown note: \(path)"
        case .occupied(let path): "A file or folder already exists at: \(path)"
        case .invalidName(let name): "Invalid name: \(name)"
        case .unresolvedLink(let target): "No note matches the link: \(target)"
        }
    }
}

private final class NullEventLogger: EventRecording, @unchecked Sendable {
    func record(level: LogLevel, event: String, fields: [String: JSONValue]) {}
}

public enum OmLog {
    public static let shared: any EventRecording = { () -> any EventRecording in
        if let logger = try? JSONEventLogger() { return logger }
        return NullEventLogger()
    }()
}

@MainActor
public final class VaultWorkspace {
    public private(set) var vaultURL: URL?
    public private(set) var tree: [VaultTreeItem] = []
    public private(set) var notes: [VaultNote] = []
    public private(set) var tabs: [VaultTab] = []
    public private(set) var activeTabID: UUID?
    public private(set) var expandedFolders: Set<String> = []
    public private(set) var sortOrder = VaultSortOrder.defaultOrder
    public private(set) var selectedFolderPath = ""
    public private(set) var searchQuery = ""
    public private(set) var searchResults: [VaultSearchMatch] = []
    public private(set) var backlinks: [String] = []
    public private(set) var properties: [NoteProperty] = []
    public private(set) var status = NoteStatus.empty
    public private(set) var errorMessage: String?
    public private(set) var indexRevision = 0
    /// Every note this window has opened, in order, and where in that order
    /// the arrows currently stand. Per-tab history left both arrows grey for
    /// anyone who only clicked around the tree.
    public private(set) var history: [String] = []
    public private(set) var historyIndex = -1

    public var activeTab: VaultTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    public var activePath: String? { activeTab?.path }
    public var activeText: String { activeTab?.text ?? "" }
    public var canGoBack: Bool { historyIndex > 0 }
    public var canGoForward: Bool { historyIndex + 1 < history.count }
    public var resolvedLinkIdentifiers: Set<String> {
        guard let sourcePath = activePath else { return [] }
        return Set(linksReport.links.filter { $0.from == sourcePath }.map { link in
            if let alias = link.alias { return alias }
            if let anchor = link.anchor { return "\(link.target)#\(anchor)" }
            return link.target
        })
    }
    public var editorResolvedLinkIdentifiers: Set<String> {
        guard let sourcePath = activePath else { return [] }
        var result = resolvedLinkIdentifiers
        let text = activeText as NSString
        let expression = try? NSRegularExpression(pattern: #"\|((?:om-v1:)[^\]]+)\]\]"#)
        for match in expression?.matches(
            in: activeText, range: NSRange(location: 0, length: text.length)
        ) ?? [] {
            let identifier = text.substring(with: match.range(at: 1))
            if resolvedPath(for: identifier, from: sourcePath) != nil {
                result.insert(identifier)
            }
        }
        return result
    }

    /// Not scoped to a vault: it is what tells the next launch which vault to
    /// reopen at all.
    private static let lastVaultKey = "om.lastVault"

    private let logger: any EventRecording
    private let preferences: UserDefaults
    private let linkInspector: VaultLinkInspector
    private var linksReport = VaultLinksReport(links: [], broken: [])
    private var diskSignature = ""

    public init(
        logger: any EventRecording = OmLog.shared,
        preferences: UserDefaults = .standard,
        linkInspector: VaultLinkInspector = VaultLinkInspector()
    ) {
        self.logger = logger
        self.preferences = preferences
        self.linkInspector = linkInspector
    }

    public func openVault(at url: URL) throws {
        vaultURL = url.standardizedFileURL
        loadPreferences()
        tabs = []
        activeTabID = nil
        selectedFolderPath = ""
        searchQuery = ""
        searchResults = []
        try rebuildIndex()
        clearActiveDetails()
        errorMessage = nil
        preferences.set(vaultURL?.path, forKey: Self.lastVaultKey)
        restoreTabs()
        logger.record(level: .info, event: "vault.opened", fields: [
            "path": .string(vaultURL?.path ?? ""),
        ])
    }

    /// Reopens the vault and the tabs the last session left behind. Returns
    /// false when there is nothing to restore, so a first run still shows the
    /// empty state instead of an error.
    @discardableResult
    public func restoreLastSession() -> Bool {
        guard let path = preferences.string(forKey: Self.lastVaultKey) else { return false }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try openVault(at: url)
            return true
        } catch {
            return false
        }
    }

    public func setFolderExpanded(_ path: String, expanded: Bool) {
        if expanded { expandedFolders.insert(path) } else { expandedFolders.remove(path) }
        savePreferences()
    }

    public func selectFolder(_ path: String) {
        selectedFolderPath = path
    }

    public func setSortOrder(_ order: VaultSortOrder) {
        sortOrder = order
        tree = sorted(tree)
        savePreferences()
    }

    /// Opens a note in a tab of its own, as selecting one from the tree
    /// always has. The back and forward arrows do not depend on this: they
    /// walk the window's own history, which every open adds to.
    public func openNote(at path: String) throws {
        try openNote(at: path, logEvent: true, addToHistory: false)
    }

    /// Kept as the explicit spelling; identical to `openNote(at:)`.
    public func openNoteInNewTab(at path: String) throws {
        try openNote(at: path, logEvent: true, addToHistory: false)
    }

    @discardableResult
    public func createNote(named requestedName: String? = nil, in folder: String? = nil) throws -> String {
        do {
            let root = try requireVault()
            let directory = try validatedDirectory(folder ?? selectedFolderPath, root: root)
            let filename: String
            if let requestedName {
                guard isValidLeafName(requestedName) else { throw VaultWorkspaceError.invalidName(requestedName) }
                filename = (requestedName as NSString).pathExtension.lowercased() == "md"
                    ? requestedName : "\(requestedName).md"
                guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path) else {
                    throw VaultWorkspaceError.occupied(filename)
                }
            } else {
                var number = 1
                var candidate = "Untitled.md"
                while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
                    number += 1
                    candidate = "Untitled \(number).md"
                }
                filename = candidate
            }
            let destination = directory.appendingPathComponent(filename)
            try "# \(destination.deletingPathExtension().lastPathComponent)\n".write(
                to: destination, atomically: true, encoding: .utf8
            )
            try rebuildIndex()
            let path = relativePath(of: destination, root: root)
            try openNote(at: path, logEvent: false, addToHistory: false)
            logger.record(level: .info, event: "note.created", fields: ["path": .string(path)])
            return path
        } catch {
            reject(error)
            throw error
        }
    }

    @discardableResult
    public func createFolder(named name: String = "New Folder", in folder: String? = nil) throws -> String {
        do {
            let root = try requireVault()
            guard isValidLeafName(name) else { throw VaultWorkspaceError.invalidName(name) }
            let directory = try validatedDirectory(folder ?? selectedFolderPath, root: root)
            let destination = directory.appendingPathComponent(name, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw VaultWorkspaceError.occupied(relativePath(of: destination, root: root))
            }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try rebuildIndex()
            let path = relativePath(of: destination, root: root)
            logger.record(level: .info, event: "folder.created", fields: ["path": .string(path)])
            return path
        } catch {
            reject(error)
            throw error
        }
    }

    public func renameNote(at path: String, to newName: String) throws {
        do {
            let root = try requireVault()
            let report = try VaultRenamer().rename(vaultAt: root, from: path, to: newName)
            for index in tabs.indices {
                if tabs[index].path == report.renamed.from { tabs[index].path = report.renamed.to }
                tabs[index].history = tabs[index].history.map {
                    $0 == report.renamed.from ? report.renamed.to : $0
                }
            }
            try rebuildIndex()
            refreshTabTitles()
            refreshActiveDetails()
            logger.record(level: .info, event: "note.renamed", fields: [
                "from": .string(report.renamed.from),
                "to": .string(report.renamed.to),
                "updated": .integer(report.updated.count),
            ])
        } catch {
            reject(error)
            throw error
        }
    }

    /// Deletes a note or a folder and closes whatever tabs it held. Links
    /// pointing at a deleted note are left alone: they simply become broken,
    /// which `om links` already reports.
    public func deleteItem(at path: String) throws {
        do {
            let root = try requireVault()
            let target = root.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
                throw VaultWorkspaceError.unknownNote(path)
            }
            let folder = isDirectory.boolValue
            try FileManager.default.removeItem(at: target)
            let prefix = path + "/"
            for tab in tabs where tab.path == path || tab.path.hasPrefix(prefix) {
                closeTab(id: tab.id)
            }
            if selectedFolderPath == path || selectedFolderPath.hasPrefix(prefix) {
                selectedFolderPath = ""
            }
            expandedFolders = expandedFolders.filter { $0 != path && !$0.hasPrefix(prefix) }
            try rebuildIndex()
            refreshActiveDetails()
            savePreferences()
            logger.record(
                level: .info,
                event: folder ? "folder.deleted" : "note.deleted",
                fields: ["path": .string(path)]
            )
        } catch {
            reject(error)
            throw error
        }
    }

    public func closeTab(id: UUID) {
        defer { savePreferences() }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = activeTabID == id
        let path = tabs[index].path
        tabs.remove(at: index)
        if wasActive {
            activeTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
        refreshActiveDetails()
        logger.record(level: .info, event: "tab.closed", fields: ["path": .string(path)])
    }

    public func activateTab(id: UUID) {
        defer { savePreferences() }
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
        refreshActiveDetails()
    }

    public func updateActiveText(_ text: String) throws {
        guard let index = activeTabIndex else { throw VaultWorkspaceError.noActiveNote }
        tabs[index].text = text
        tabs[index].isDirty = true
    }

    public func saveActiveNote() throws {
        guard let root = vaultURL, let index = activeTabIndex else {
            throw VaultWorkspaceError.noActiveNote
        }
        let path = tabs[index].path
        let source = EditorMarkupAdapter.decode(tabs[index].text)
        try source.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        tabs[index].text = EditorMarkupAdapter.encode(source)
        tabs[index].isDirty = false
        try rebuildIndex()
        refreshTabTitles()
        refreshActiveDetails()
        logger.record(level: .info, event: "note.saved", fields: ["path": .string(path)])
    }

    public func followWikiLink(_ identifier: String) throws {
        guard let index = activeTabIndex else { throw VaultWorkspaceError.noActiveNote }
        let sourcePath = tabs[index].path
        if tabs[index].isDirty, let root = vaultURL {
            let source = EditorMarkupAdapter.decode(tabs[index].text)
            try source.write(to: root.appendingPathComponent(sourcePath), atomically: true, encoding: .utf8)
            tabs[index].isDirty = false
            try rebuildIndex()
        }
        guard let targetPath = resolvedPath(for: identifier, from: sourcePath),
              let target = notes.first(where: { $0.path == targetPath }) else {
            throw VaultWorkspaceError.unresolvedLink(EditorMarkupAdapter.destination(from: identifier))
        }
        if let existing = tabs.first(where: { $0.path == target.path }) {
            activeTabID = existing.id
            refreshActiveDetails()
        } else {
            try navigateActiveTab(to: target.path, historyEvent: nil)
        }
        logger.record(level: .info, event: "note.opened", fields: ["path": .string(target.path)])
    }

    public func goBack() throws {
        guard canGoBack else { return }
        historyIndex -= 1
        try revisit(history[historyIndex], event: "history.back")
    }

    public func goForward() throws {
        guard canGoForward else { return }
        historyIndex += 1
        try revisit(history[historyIndex], event: "history.forward")
    }

    /// Shows a note the arrows landed on without disturbing the history it
    /// came from. A note whose tab is gone gets a new one.
    private func revisit(_ path: String, event: String) throws {
        guard notes.contains(where: { $0.path == path }) else { return }
        if let existing = tabs.first(where: { $0.path == path }) {
            activeTabID = existing.id
        } else if let index = activeTabIndex {
            try load(path: path, into: index)
        } else {
            try openNote(at: path, logEvent: false, addToHistory: false)
        }
        refreshActiveDetails()
        savePreferences()
        logger.record(level: .info, event: event, fields: ["path": .string(path)])
    }

    /// Records a visit unless the arrows are what caused it.
    private func recordVisit(_ path: String) {
        if historyIndex >= 0, history.indices.contains(historyIndex), history[historyIndex] == path {
            return
        }
        history = Array(history.prefix(historyIndex + 1)) + [path]
        historyIndex = history.count - 1
    }

    public func performSearch(_ query: String) throws {
        let root = try requireVault()
        searchQuery = query
        searchResults = try VaultSearcher().search(vaultAt: root, query: query).matches
        logger.record(level: .info, event: "search.performed", fields: [
            "query": .string(query),
            "matches": .integer(searchResults.count),
        ])
    }

    public func refreshForExternalChanges() throws {
        guard let root = vaultURL else { return }
        let current = try signature(for: root)
        guard current != diskSignature else { return }
        try rebuildIndex()
        refreshTabTitles()
        refreshActiveDetails()
    }

    public func reportRenderFailure(exception: String, reason: String, stack: [String]) {
        errorMessage = reason
        logger.record(level: .error, event: "render.failed", fields: [
            "exception": .string(exception),
            "reason": .string(reason),
            "stack": .strings(stack),
        ])
    }

    public func clearError() { errorMessage = nil }

    public func resetTabs() {
        tabs = []
        activeTabID = nil
        clearActiveDetails()
    }

    private var activeTabIndex: Int? {
        guard let activeTabID else { return nil }
        return tabs.firstIndex { $0.id == activeTabID }
    }

    private func openNote(at path: String, logEvent: Bool, addToHistory: Bool) throws {
        guard notes.contains(where: { $0.path == path }) else { throw VaultWorkspaceError.unknownNote(path) }
        if let existing = tabs.first(where: { $0.path == path }) {
            activeTabID = existing.id
        } else if addToHistory, activeTabIndex != nil {
            try navigateActiveTab(to: path, historyEvent: nil)
        } else {
            let note = notes.first { $0.path == path }!
            let source = try readSource(at: path)
            let tab = VaultTab(
                id: UUID(), path: path, title: displayName(for: path),
                text: EditorMarkupAdapter.encode(source), isDirty: false,
                history: [path], historyIndex: 0
            )
            tabs.append(tab)
            activeTabID = tab.id
        }
        recordVisit(path)
        refreshActiveDetails()
        savePreferences()
        if logEvent {
            logger.record(level: .info, event: "note.opened", fields: ["path": .string(path)])
        }
    }

    private func navigateActiveTab(to path: String, historyEvent: String?) throws {
        guard let index = activeTabIndex else {
            try openNote(at: path, logEvent: false, addToHistory: false)
            return
        }
        let nextIndex = tabs[index].historyIndex + 1
        tabs[index].history = Array(tabs[index].history.prefix(nextIndex)) + [path]
        tabs[index].historyIndex = nextIndex
        try load(path: path, into: index)
        recordVisit(path)
        if let historyEvent {
            logger.record(level: .info, event: historyEvent, fields: ["path": .string(path)])
        }
    }

    private func resolvedPath(for identifier: String, from sourcePath: String) -> String? {
        let destination = EditorMarkupAdapter.destination(from: identifier)
            .trimmingCharacters(in: .whitespaces)
        return linksReport.links.first { link in
            guard link.from == sourcePath else { return false }
            if link.alias == identifier { return true }
            let resolvedIdentifier = link.anchor.map { "\(link.target)#\($0)" } ?? link.target
            return resolvedIdentifier.caseInsensitiveCompare(destination) == .orderedSame
        }?.resolved
    }

    private func load(path: String, into index: Int) throws {
        let note = notes.first { $0.path == path }
        tabs[index].path = path
        _ = note
        tabs[index].title = displayName(for: path)
        tabs[index].text = EditorMarkupAdapter.encode(try readSource(at: path))
        tabs[index].isDirty = false
        refreshActiveDetails()
    }

    /// The name shown for a note: its file name, never its first heading.
    /// The two diverge the moment a note is renamed.
    private func displayName(for path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    private func readSource(at path: String) throws -> String {
        guard let vaultURL else { throw VaultWorkspaceError.noVault }
        return try String(contentsOf: vaultURL.appendingPathComponent(path), encoding: .utf8)
    }

    private func rebuildIndex() throws {
        guard let root = vaultURL else { throw VaultWorkspaceError.noVault }
        let inventory = try VaultIndexer().index(vaultAt: root)
        let report = try linkInspector.inspect(vaultAt: root)
        notes = inventory.notes
        linksReport = report
        tree = try buildTree(at: root, relativePath: "", titles: Dictionary(
            uniqueKeysWithValues: inventory.notes.map { ($0.path, $0.title) }
        ))
        tree = sorted(tree)
        indexRevision += 1
        diskSignature = try signature(for: root)
    }

    private func buildTree(
        at directory: URL,
        relativePath: String,
        titles: [String: String]
    ) throws -> [VaultTreeItem] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: []
        ).compactMap { child in
            let values = try child.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { return nil }
            let path = relativePath.isEmpty ? child.lastPathComponent : "\(relativePath)/\(child.lastPathComponent)"
            let modified = values.contentModificationDate ?? .distantPast
            if values.isDirectory == true {
                return VaultTreeItem(
                    kind: .folder, path: path, title: child.lastPathComponent,
                    modifiedAt: modified,
                    children: try buildTree(at: child, relativePath: path, titles: titles)
                )
            }
            guard values.isRegularFile == true, child.pathExtension.lowercased() == "md" else { return nil }
            // The file name, not the note's first heading. Renaming a note
            // changes the file and leaves the heading alone, so a tree showing
            // the heading looked as though the rename had not happened.
            return VaultTreeItem(
                kind: .note, path: path,
                title: child.deletingPathExtension().lastPathComponent,
                modifiedAt: modified
            )
        }
    }

    private func sorted(_ items: [VaultTreeItem]) -> [VaultTreeItem] {
        items.map {
            VaultTreeItem(
                kind: $0.kind, path: $0.path, title: $0.title,
                modifiedAt: $0.modifiedAt, children: sorted($0.children)
            )
        }.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch sortOrder.field {
            case .name:
                comparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            case .modified:
                comparison = lhs.modifiedAt == rhs.modifiedAt
                    ? lhs.path.compare(rhs.path) : (lhs.modifiedAt < rhs.modifiedAt ? .orderedAscending : .orderedDescending)
            }
            let resolved = comparison == .orderedSame ? lhs.path.compare(rhs.path) : comparison
            return sortOrder.direction == .ascending
                ? resolved == .orderedAscending : resolved == .orderedDescending
        }
    }

    private func refreshTabTitles() {
        for index in tabs.indices {
            tabs[index].title = displayName(for: tabs[index].path)
        }
    }

    private func refreshActiveDetails() {
        guard let tab = activeTab else {
            clearActiveDetails()
            return
        }
        let source = EditorMarkupAdapter.decode(tab.text)
        properties = parseProperties(source)
        backlinks = (try? vaultURL.map {
            try VaultBacklinkFinder().find(vaultAt: $0, noteName: tab.path).backlinks
        }) ?? []
        let expression = try? NSRegularExpression(pattern: #"[\p{L}\p{N}_]+"#)
        let range = NSRange(location: 0, length: (source as NSString).length)
        status = NoteStatus(
            words: expression?.numberOfMatches(in: source, range: range) ?? 0,
            characters: source.count,
            backlinks: backlinks.count,
            properties: properties.count
        )
    }

    private func clearActiveDetails() {
        backlinks = []
        properties = []
        status = .empty
    }

    private func parseProperties(_ source: String) -> [NoteProperty] {
        let lines = source.components(separatedBy: .newlines)
        guard lines.first == "---" else { return [] }
        var result: [NoteProperty] = []
        for line in lines.dropFirst() {
            if line == "---" { return result }
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { result.append(NoteProperty(name: name, value: value)) }
        }
        return []
    }

    private func validatedDirectory(_ relative: String, root: URL) throws -> URL {
        guard relative.isEmpty || (!relative.hasPrefix("/") && !relative.split(separator: "/").contains("..")) else {
            throw VaultWorkspaceError.invalidName(relative)
        }
        let url = relative.isEmpty ? root : root.appendingPathComponent(relative, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw VaultWorkspaceError.invalidName(relative)
        }
        return url
    }

    private func isValidLeafName(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value != "." && value != ".." && !value.contains("/")
    }

    private func requireVault() throws -> URL {
        guard let vaultURL else { throw VaultWorkspaceError.noVault }
        return vaultURL
    }

    private func relativePath(of url: URL, root: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    private func preferencePrefix() -> String? {
        guard let vaultURL else { return nil }
        return "om.vault." + Data(vaultURL.path.utf8).base64EncodedString()
    }

    private func loadPreferences() {
        guard let prefix = preferencePrefix() else { return }
        expandedFolders = Set(preferences.stringArray(forKey: prefix + ".expanded") ?? [])
        if let field = preferences.string(forKey: prefix + ".sort.field").flatMap(VaultSortField.init(rawValue:)),
           let direction = preferences.string(forKey: prefix + ".sort.direction").flatMap(VaultSortDirection.init(rawValue:)) {
            sortOrder = VaultSortOrder(field: field, direction: direction)
        } else {
            sortOrder = .defaultOrder
        }
    }

    private func savePreferences() {
        guard let prefix = preferencePrefix() else { return }
        preferences.set(expandedFolders.sorted(), forKey: prefix + ".expanded")
        preferences.set(sortOrder.field.rawValue, forKey: prefix + ".sort.field")
        preferences.set(sortOrder.direction.rawValue, forKey: prefix + ".sort.direction")
        preferences.set(tabs.map(\.path), forKey: prefix + ".tabs")
        preferences.set(activeTab?.path, forKey: prefix + ".tabs.active")
    }

    /// Reopens the tabs the previous session left, dropping any whose note is
    /// gone. A vault edited elsewhere between sessions must not produce an
    /// error on launch.
    private func restoreTabs() {
        guard let prefix = preferencePrefix() else { return }
        let saved = preferences.stringArray(forKey: prefix + ".tabs") ?? []
        let active = preferences.string(forKey: prefix + ".tabs.active")
        for path in saved where notes.contains(where: { $0.path == path }) {
            try? openNote(at: path, logEvent: false, addToHistory: false)
        }
        if let active, let tab = tabs.first(where: { $0.path == active }) {
            activeTabID = tab.id
        }
        refreshActiveDetails()
    }

    private func signature(for root: URL) throws -> String {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey,
            ],
            options: [.skipsHiddenFiles]
        ) else { return "" }
        var parts: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey,
            ])
            let path = relativePath(of: url, root: root)
            if values.isDirectory == true {
                parts.append("D|\(path)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)")
            } else if values.isRegularFile == true, url.pathExtension.lowercased() == "md" {
                parts.append("F|\(path)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values.fileSize ?? 0)")
            }
        }
        return parts.sorted().joined(separator: "\n")
    }

    private func reject(_ error: Error) {
        errorMessage = error.localizedDescription
        logger.record(level: .warn, event: "operation.rejected", fields: [
            "reason": .string(error.localizedDescription),
        ])
    }
}
