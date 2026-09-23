import Foundation

/// A cleanup category (Xcode, Android, Docker…).
protocol CleanModule: Sendable {
    var id: String { get }
    var title: String { get }
    var icon: String { get }       // SF Symbol
    var summary: String { get }
    func scan() async -> ScanResult
}

struct ScanResult: Sendable, Codable {
    var items: [CleanItem] = []
    /// Notes shown to the user (e.g. "Docker is not running").
    var notes: [String] = []
}

/// Describes a path to measure and possibly delete.
struct PathSpec: Sendable {
    var url: URL
    var title: String
    var group: String
    var safety: Safety = .safe
    var note: String? = nil
    var contentsOnly: Bool = false
    var selected: Bool = true
    var blocking: [String] = []
    /// Command to run before deleting (e.g. stop a daemon).
    var preCommand: ShellCommand? = nil

    init(_ url: URL, _ title: String, group: String, safety: Safety = .safe, note: String? = nil,
         contentsOnly: Bool = false, selected: Bool? = nil, blocking: [String] = [], preCommand: ShellCommand? = nil) {
        self.url = url
        self.title = title
        self.group = group
        self.safety = safety
        self.note = note
        self.contentsOnly = contentsOnly
        self.selected = selected ?? (safety == .safe)
        self.blocking = blocking
        self.preCommand = preCommand
    }

    init(home rel: String, _ title: String, group: String, safety: Safety = .safe, note: String? = nil,
         contentsOnly: Bool = false, selected: Bool? = nil, blocking: [String] = [], preCommand: ShellCommand? = nil) {
        self.init(.homePath(rel), title, group: group, safety: safety, note: note, contentsOnly: contentsOnly,
                  selected: selected, blocking: blocking, preCommand: preCommand)
    }
}

enum ScanKit {
    /// Measures sizes in parallel, dropping missing / empty items.
    static func measure(_ specs: [PathSpec], minSize: Int64 = 64 * 1024) async -> [CleanItem] {
        let existing = specs.filter { $0.url.exists }
        let items: [CleanItem?] = await concurrentMap(existing) { spec in
            let size: Int64
            if spec.contentsOnly {
                size = DiskUsage.size(ofPaths: spec.url.children().map(\.path))
            } else {
                size = DiskUsage.size(of: spec.url)
            }
            guard size >= minSize else { return nil }
            let action: CleanAction
            if let pre = spec.preCommand {
                action = .commandThenDelete(pre, spec.url)
            } else {
                action = spec.contentsOnly ? .deleteContents(spec.url) : .delete(spec.url)
            }
            return CleanItem(
                id: "path:" + spec.url.standardizedFileURL.path + (spec.contentsOnly ? "/*" : ""),
                title: spec.title,
                detail: spec.url.path.abbreviatingHome + (spec.contentsOnly ? "/*" : ""),
                group: spec.group,
                size: size,
                safety: spec.safety,
                note: spec.note,
                action: action,
                selectedByDefault: spec.selected,
                lastModified: spec.url.modificationDate,
                blockingProcesses: spec.blocking)
        }
        return items.compactMap { $0 }
    }

    /// Creates a spec per subfolder (e.g. each DeviceSupport version).
    static func children(
        of url: URL, group: String, safety: Safety = .safe, note: String? = nil, selected: Bool? = nil,
        includeHidden: Bool = false, blocking: [String] = [],
        filter: (URL) -> Bool = { _ in true }, title: (URL) -> String = { $0.lastPathComponent }
    ) -> [PathSpec] {
        url.children(includeHidden: includeHidden).filter(filter).map {
            PathSpec($0, title($0), group: group, safety: safety, note: note, selected: selected, blocking: blocking)
        }
    }

    /// Compares version strings ("8.14.3" > "8.9").
    static func versionLess(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.numeric, .caseInsensitive]) == .orderedAscending
    }

    static func commandItem(
        id: String, title: String, group: String, command: ShellCommand, size: Int64 = 0,
        safety: Safety = .safe, note: String? = nil, selected: Bool? = nil, detail: String? = nil
    ) -> CleanItem {
        CleanItem(id: id, title: title, detail: detail ?? "$ " + command.display, group: group, size: size,
                  safety: safety, note: note, action: .command(command),
                  selectedByDefault: selected ?? (safety == .safe), lastModified: nil)
    }
}
