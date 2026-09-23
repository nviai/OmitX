import Foundation

/// How safe it is to delete an item.
enum Safety: Int, Comparable, Hashable, CaseIterable, Codable, Sendable {
    /// Caches / temporary files — regenerated automatically, safe to delete.
    case safe
    /// Can be re-downloaded or rebuilt but takes time, or may be in use.
    case caution
    /// May lose real data (Docker volumes, signed Archives, venvs…).
    case danger

    static func < (a: Safety, b: Safety) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .safe: L("An toàn")
        case .caution: L("Cân nhắc")
        case .danger: L("Nguy hiểm")
        }
    }
}

/// A CLI command used for cleaning (docker prune, brew cleanup, simctl…).
struct ShellCommand: Hashable, Codable, Sendable {
    var executable: String      // command name, looked up in the user's PATH (e.g. "docker")
    var arguments: [String]
    var admin: Bool = false     // run with admin rights (prompts for a password)

    var display: String { ([executable] + arguments).map(Shell.quote).joined(separator: " ") }
}

enum CleanAction: Hashable, Sendable {
    /// Delete the whole path.
    case delete(URL)
    /// Delete everything inside, keeping the folder itself.
    case deleteContents(URL)
    /// Run a command.
    case command(ShellCommand)
    /// Run a command first (e.g. stop the Gradle daemon), then delete.
    case commandThenDelete(ShellCommand, URL)
    /// Delete several paths together (e.g. an AVD = the .avd folder + the .ini file).
    case deletePaths([URL])
    /// Always move to the Trash (used for .app bundles), falling back to admin when permission is missing.
    case recycle(URL)
}

struct CleanItem: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var title: String
    var detail: String?          // path or short description
    var group: String            // subgroup within the module
    var size: Int64              // estimated bytes reclaimed
    var safety: Safety
    var note: String?            // explanation / warning
    var action: CleanAction
    var selectedByDefault: Bool
    var lastModified: Date?
    /// Process that should be quit before cleaning (shows a warning).
    var blockingProcesses: [String] = []

    var path: URL? {
        switch action {
        case .delete(let u), .deleteContents(let u), .commandThenDelete(_, let u), .recycle(let u): u
        case .deletePaths(let us): us.first
        case .command: nil
        }
    }

    var paths: [URL] {
        if case .deletePaths(let us) = action { return us }
        return path.map { [$0] } ?? []
    }

    /// Needs the admin password — cannot run in the background agent.
    var needsAdmin: Bool {
        switch action {
        case .command(let c), .commandThenDelete(let c, _): c.admin
        default: false
        }
    }

    var actionDescription: String {
        switch action {
        case .delete(let u): L("Xoá \(u.path.abbreviatingHome)")
        case .deleteContents(let u): L("Xoá nội dung \(u.path.abbreviatingHome)/*")
        case .command(let c): "$ \(c.display)"
        case .commandThenDelete(let c, let u): L("$ \(c.display) → xoá \(u.path.abbreviatingHome)")
        case .recycle(let u): L("Chuyển \(u.path.abbreviatingHome) vào Thùng rác")
        case .deletePaths(let us): L("Xoá \(us.map { $0.path.abbreviatingHome }.joined(separator: ", "))")
        }
    }
}

extension CleanItem {
    /// Drops items nested inside another item in the list, so sizes are not counted twice.
    static func removeNested(_ items: [CleanItem]) -> [CleanItem] {
        let all = Set(items.flatMap(\.paths).map(\.standardizedFileURL.path))
        return items.filter { item in
            guard var p = item.path?.standardizedFileURL.path else { return true }
            // Walk up the parent folders; if a parent is also in the list, drop this item
            while let slash = p.lastIndex(of: "/"), slash != p.startIndex {
                p = String(p[..<slash])
                if all.contains(p) { return false }
            }
            return true
        }
    }
}

extension CleanAction: Codable {
    private enum Kind: String, Codable {
        case delete, deleteContents, command, commandThenDelete, deletePaths, recycle
    }
    private enum CodingKeys: String, CodingKey { case kind, url, urls, command }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .delete(let u):
            try c.encode(Kind.delete, forKey: .kind); try c.encode(u, forKey: .url)
        case .deleteContents(let u):
            try c.encode(Kind.deleteContents, forKey: .kind); try c.encode(u, forKey: .url)
        case .command(let cmd):
            try c.encode(Kind.command, forKey: .kind); try c.encode(cmd, forKey: .command)
        case .commandThenDelete(let cmd, let u):
            try c.encode(Kind.commandThenDelete, forKey: .kind)
            try c.encode(cmd, forKey: .command); try c.encode(u, forKey: .url)
        case .deletePaths(let us):
            try c.encode(Kind.deletePaths, forKey: .kind); try c.encode(us, forKey: .urls)
        case .recycle(let u):
            try c.encode(Kind.recycle, forKey: .kind); try c.encode(u, forKey: .url)
        }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .delete: self = .delete(try c.decode(URL.self, forKey: .url))
        case .deleteContents: self = .deleteContents(try c.decode(URL.self, forKey: .url))
        case .command: self = .command(try c.decode(ShellCommand.self, forKey: .command))
        case .commandThenDelete:
            self = .commandThenDelete(try c.decode(ShellCommand.self, forKey: .command),
                                      try c.decode(URL.self, forKey: .url))
        case .deletePaths: self = .deletePaths(try c.decode([URL].self, forKey: .urls))
        case .recycle: self = .recycle(try c.decode(URL.self, forKey: .url))
        }
    }
}

extension String {
    var abbreviatingHome: String {
        let home = NSHomeDirectory()
        return hasPrefix(home) ? "~" + dropFirst(home.count) : self
    }
}

extension URL {
    static let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    static func homePath(_ rel: String) -> URL { home.appendingPathComponent(rel) }

    var exists: Bool { FileManager.default.fileExists(atPath: path) }
    var isDirectory: Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &d) && d.boolValue
    }
    var modificationDate: Date? {
        (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
    /// Direct children (ignoring .DS_Store).
    func children(includeHidden: Bool = true) -> [URL] {
        let opts: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        let list = (try? FileManager.default.contentsOfDirectory(
            at: self, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: opts)) ?? []
        return list.filter { $0.lastPathComponent != ".DS_Store" }
    }
}

enum ByteFormat {
    /// "0 bytes" instead of "Zero KB".
    nonisolated(unsafe) private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    static func string(_ bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }

    /// Parses "2.619GB", "746.3MB (26%)", "0B" (docker's format).
    static func parse(_ text: String) -> Int64 {
        let s = text.split(separator: " ").first.map(String.init) ?? text
        let scanner = Scanner(string: s)
        guard let value = scanner.scanDouble() else { return 0 }
        let unit = s[scanner.currentIndex...].uppercased()
        let mult: Double = switch unit {
        case "KB", "K", "KIB": 1_000
        case "MB", "M", "MIB": 1_000_000
        case "GB", "G", "GIB": 1_000_000_000
        case "TB", "T", "TIB": 1_000_000_000_000
        default: 1
        }
        return Int64(value * mult)
    }
}
