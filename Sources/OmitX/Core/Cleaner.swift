import Foundation
import AppKit

enum DeleteMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case permanent, trash
    var id: String { rawValue }
    var label: String {
        switch self {
        case .permanent: L("Xoá vĩnh viễn (giải phóng ngay)")
        case .trash: L("Chuyển vào Thùng rác")
        }
    }
}

enum CleanError: LocalizedError {
    case protectedPath(String)
    var errorDescription: String? {
        switch self {
        case .protectedPath(let p): L("Đường dẫn được bảo vệ, không xoá: \(p)")
        }
    }
}

struct CleanOutcome: Identifiable {
    let id = UUID()
    let item: CleanItem
    let freed: Int64
    let error: String?
    let output: String?
}

/// Performs the cleanup. Independent of the UI.
enum Cleaner {
    /// Absolute paths that must never be deleted (the path itself).
    static let protectedPaths: Set<String> = {
        let h = NSHomeDirectory()
        var s: Set<String> = ["/", "/System", "/Library", "/Applications", "/Users", "/usr", "/bin", "/sbin",
                              "/private", "/private/var", "/opt", "/opt/homebrew", "/Volumes", "/cores", "/etc", "/var", "/tmp"]
        for rel in ["", "Library", "Library/Application Support", "Library/Caches", "Library/Containers",
                    "Library/Group Containers", "Library/Preferences", "Library/Developer", "Library/Mobile Documents",
                    "Library/CloudStorage", "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music",
                    "Applications", "Workspaces", "Projects", "Developer", "go", ".ssh", ".gnupg", ".config"] {
            s.insert(rel.isEmpty ? h : "\(h)/\(rel)")
        }
        return s
    }()

    static func validate(_ url: URL) throws {
        let p = url.standardizedFileURL.path
        guard p.hasPrefix("/"), p.count > 1, !protectedPaths.contains(p) else {
            throw CleanError.protectedPath(p)
        }
        // Block everything inside the immutable system area.
        for bad in ["/System/", "/usr/", "/bin/", "/sbin/"] where p.hasPrefix(bad) {
            throw CleanError.protectedPath(p)
        }
        // Block sensitive personal data
        for bad in [".ssh", ".gnupg", "Library/Keychains", "Library/Mail", "Library/Messages", "Library/Photos"] {
            if p.hasPrefix("\(NSHomeDirectory())/\(bad)") { throw CleanError.protectedPath(p) }
        }
    }

    /// Folders that must never have "all contents" deleted.
    static func validateContainer(_ url: URL) throws {
        let p = url.standardizedFileURL.path
        let h = NSHomeDirectory()
        let blocked: Set<String> = ["/", "/Users", "/System", "/Library", "/Applications", "/private", "/opt", h,
                                    "\(h)/Library", "\(h)/Library/Application Support", "\(h)/Library/Containers",
                                    "\(h)/Library/Group Containers", "\(h)/Library/Preferences",
                                    "\(h)/Documents", "\(h)/Desktop", "\(h)/Downloads"]
        guard p.hasPrefix("/"), !blocked.contains(p), !p.hasPrefix("/System/") else {
            throw CleanError.protectedPath(p)
        }
    }

    static func clean(_ item: CleanItem, mode: DeleteMode) async -> CleanOutcome {
        do {
            let output: String?
            switch item.action {
            case .delete(let url):
                try await remove(url, mode: mode)
                output = nil
            case .deleteContents(let url):
                try validateContainer(url)
                var errors: [String] = []
                for child in url.children() {
                    do { try await remove(child, mode: mode) } catch { errors.append(error.localizedDescription) }
                }
                output = errors.isEmpty ? nil : L("\(errors.count) mục không xoá được (đang bị dùng hoặc thiếu quyền)")
            case .command(let cmd):
                output = try await run(cmd)
            case .recycle(let url):
                try validate(url)
                do {
                    try await NSWorkspace.shared.recycle([url])
                } catch {
                    // App owned by root (App Store / pkg) → needs admin rights
                    _ = try await Shell.runAdmin("/bin/rm -rf \(Shell.quote(url.path))")
                }
                output = nil
            case .deletePaths(let urls):
                for url in urls { try await remove(url, mode: mode) }
                output = nil
            case .commandThenDelete(let cmd, let url):
                _ = try? await run(cmd) // stopping a daemon fails when none is running — ignore
                try await remove(url, mode: mode)
                output = nil
            }
            // Measure again to compute the space actually freed
            var freed = item.size
            if !item.paths.isEmpty {
                let paths = item.paths.map(\.path)
                let remaining = await Task.detached { DiskUsage.size(ofPaths: paths) }.value
                freed = max(0, item.size - remaining)
            }
            return CleanOutcome(item: item, freed: freed, error: nil, output: output)
        } catch {
            return CleanOutcome(item: item, freed: 0, error: error.localizedDescription, output: nil)
        }
    }

    static func run(_ cmd: ShellCommand) async throws -> String {
        if cmd.admin {
            guard let exe = Shell.which(cmd.executable) else { throw ShellError.notFound(cmd.executable) }
            return try await Shell.runAdmin(([exe] + cmd.arguments).map(Shell.quote).joined(separator: " "))
        }
        let r = try await Shell.runAsync(cmd.executable, cmd.arguments)
        guard r.ok else { throw ShellError.failed(cmd.display, r) }
        return r.combined
    }

    static func remove(_ url: URL, mode: DeleteMode) async throws {
        try validate(url)
        guard url.exists || DiskUsage.isSymlink(url.path) else { return }
        switch mode {
        case .trash:
            try await NSWorkspace.shared.recycle([url])
        case .permanent:
            try await Task.detached(priority: .userInitiated) {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    // The Go module cache and some tools leave files read-only → make them writable and retry.
                    _ = try? Shell.runRaw("/bin/chmod", ["-R", "u+w", url.path], env: Shell.environment, timeout: 600)
                    let r = try Shell.runRaw("/bin/rm", ["-rf", url.path], env: Shell.environment, timeout: 1800)
                    if !r.ok, url.exists { throw ShellError.failed("rm -rf \(url.path)", r) }
                }
            }.value
        }
    }
}
