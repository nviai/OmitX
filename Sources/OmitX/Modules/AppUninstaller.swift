import Foundation
import AppKit

struct InstalledApp: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    let url: URL
    let name: String
    let bundleID: String?
    let version: String?
    var size: Int64 = 0
    var lastUsed: Date?
}

/// Uninstalls an app plus all its leftovers in ~/Library (a generalized rm-zalo-macos.sh).
enum AppUninstaller {
    static func listApps() async -> [InstalledApp] {
        let dirs = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Applications/Utilities"), URL.homePath("Applications")]
        var apps: [InstalledApp] = []
        for dir in dirs {
            for url in dir.children(includeHidden: false) where url.pathExtension == "app" {
                let bundle = Bundle(url: url)
                let info = bundle?.infoDictionary ?? [:]
                let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                // Skip Apple's system apps (Safari…) — they should not be uninstalled
                if let id = bundle?.bundleIdentifier, id.hasPrefix("com.apple."), !id.hasPrefix("com.apple.dt.") { continue }
                let lastUsed = (try? url.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate
                apps.append(InstalledApp(url: url, name: name, bundleID: bundle?.bundleIdentifier,
                                         version: info["CFBundleShortVersionString"] as? String, lastUsed: lastUsed))
            }
        }
        let sized: [InstalledApp] = await concurrentMap(apps, limit: 8) { app in
            var a = app
            a.size = DiskUsage.size(of: app.url)
            return a
        }
        return sized.sorted { $0.size > $1.size }
    }

    /// Places where apps usually leave data behind.
    static let userLocations = [
        "Library/Application Support", "Library/Application Support/Caches", "Library/Application Support/CrashReporter",
        "Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments",
        "Library/Caches", "Library/HTTPStorages", "Library/Preferences", "Library/Preferences/ByHost",
        "Library/Saved Application State", "Library/Containers", "Library/Group Containers", "Library/Logs",
        "Library/Logs/DiagnosticReports", "Library/WebKit", "Library/Cookies", "Library/LaunchAgents",
        "Library/Application Scripts", "Library/Autosave Information",
    ]
    static let systemLocations = [
        "/Library/Application Support", "/Library/Caches", "/Library/LaunchAgents", "/Library/LaunchDaemons",
        "/Library/PrivilegedHelperTools", "/Library/Preferences", "/Library/Logs",
    ]

    static func leftovers(for app: InstalledApp) async -> [CleanItem] {
        let bundleID = app.bundleID?.lowercased()
        let appName = normalize(app.name)
        let fileName = normalize(app.url.deletingPathExtension().lastPathComponent)

        enum Match { case bundle, exactName, prefixName }
        func match(_ entry: String) -> Match? {
            let lower = entry.lowercased()
            if let bundleID, lower == bundleID || lower.hasPrefix(bundleID + ".") || lower.hasPrefix(bundleID + "_")
                || lower.hasSuffix("." + bundleID) || lower.contains("." + bundleID + ".") { return .bundle }
            let n = normalize((entry as NSString).deletingPathExtension)
            for candidate in [appName, fileName] where candidate.count >= 3 {
                if n == candidate { return .exactName }
                if candidate.count >= 4, n.hasPrefix(candidate) { return .prefixName }
            }
            return nil
        }

        struct Hit: Sendable { let url: URL; let match: Int; let system: Bool }
        var hits: [Hit] = []
        let locations = userLocations.map { (URL.homePath($0), false) } + systemLocations.map { (URL(fileURLWithPath: $0), true) }
        // Vendor taken from the bundle ID: com.google.android.studio → "google"
        let parts = (app.bundleID ?? "").lowercased().split(separator: ".")
        let vendor = parts.count >= 3 && parts[1].count >= 3 && parts[1] != "apple" ? String(parts[1]) : nil

        for (dir, system) in locations {
            for child in dir.children() {
                // Vendor folder (Google/, JetBrains/…): keep searching inside by app name
                if let vendor, normalize(child.lastPathComponent) == vendor, child.isDirectory {
                    for inner in child.children() {
                        guard let m = match(inner.lastPathComponent) else { continue }
                        hits.append(Hit(url: inner, match: m == .bundle ? 0 : (m == .exactName ? 1 : 2), system: system))
                    }
                    continue
                }
                guard let m = match(child.lastPathComponent) else { continue }
                // Skip the location folders themselves (e.g. "Caches" inside Application Support)
                if locations.contains(where: { $0.0 == child }) { continue }
                hits.append(Hit(url: child, match: m == .bundle ? 0 : (m == .exactName ? 1 : 2), system: system))
            }
        }

        var items: [CleanItem] = [CleanItem(
            id: "app:\(app.url.path)", title: "\(app.name).app", detail: app.url.path, group: L("Ứng dụng"),
            size: app.size, safety: .caution, note: L("Chuyển vào Thùng rác"), action: .recycle(app.url),
            selectedByDefault: true, lastModified: app.lastUsed)]

        items += await concurrentMap(hits) { hit in
            let size = DiskUsage.size(of: hit.url)
            let reason = [L("khớp bundle ID"), L("khớp tên app"), L("tên bắt đầu bằng tên app — kiểm tra lại")][hit.match]
            let action: CleanAction = hit.system
                ? .command(ShellCommand(executable: "/bin/rm", arguments: ["-rf", hit.url.path], admin: true))
                : .delete(hit.url)
            return CleanItem(
                id: "leftover:\(hit.url.path)", title: hit.url.lastPathComponent,
                detail: hit.url.path.abbreviatingHome,
                group: hit.system ? L("Hệ thống (cần admin)") : hit.url.deletingLastPathComponent().path.abbreviatingHome,
                size: size, safety: hit.match == 2 ? .caution : .safe, note: reason, action: action,
                selectedByDefault: true, lastModified: hit.url.modificationDate)
        }
        return items
    }

    /// Quits the app if it is running.
    @MainActor
    static func quit(_ app: InstalledApp) async {
        guard let id = app.bundleID else { return }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
        guard !running.isEmpty else { return }
        running.forEach { $0.terminate() }
        for _ in 0..<20 where running.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
