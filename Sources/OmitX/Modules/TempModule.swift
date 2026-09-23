import Foundation
import Darwin

/// /tmp and the per-user $TMPDIR (/var/folders/…/T), where agents, test runners and build tools
/// leave logs, scratch files and whole checkouts that nothing ever removes.
///
/// An entry is only offered when all of these hold:
/// - it belongs to the current user, is a regular file or folder, and is not a symlink;
/// - it contains no socket (tmux, ssh-agent, language servers…) and no process has anything open inside it (lsof);
/// - nothing inside it was written in the last hour.
/// Untouched for `staleDays` → safe and preselected; more recent → caution, unselected.
struct TempModule: CleanModule {
    let id = "temp"
    let title = L("File tạm (/tmp)")
    let icon = "clock.arrow.circlepath"
    let summary = L("/tmp và $TMPDIR: log, scratch của AI agent, test, build tool — bỏ qua mục đang được dùng")

    /// The UI strings say "3 days" literally (a fixed number translates without plural rules) — keep them in sync.
    static let staleDays = 3
    static let activeWindow: TimeInterval = 60 * 60
    /// Loose entries smaller than this are bundled into one item per folder.
    static let bundleBelow: Int64 = 1024 * 1024
    /// Created by macOS / system services, or by tools that keep them alive across runs.
    static let skipPrefixes = ["com.apple.", "launchd", "tmux-", "ssh-", "powerlog", ".X11", ".ICE", ".font-unix",
                               "TemporaryItems", "Cleanup At Startup", "KSOutOfProcessFetcher", "xcrun_db", "vscode-git-",
                               "vscode-ipc-", "sentry"]
    static let skipSuffixes = [".sock", ".socket", ".pid", ".lock", ".lck"]

    struct Root {
        let url: URL
        let label: String
        /// Folders that hold one subfolder per project/session and are split one level further.
        let containers: Set<String>
    }

    func scan() async -> ScanResult {
        let uid = getuid()
        var roots = [Root(url: URL(fileURLWithPath: "/private/tmp"), label: "/tmp",
                          containers: ["claude-\(uid)", "claude"])]
        if let t = Self.userTempDir() {
            roots.append(Root(url: t, label: "$TMPDIR", containers: ["claude-\(uid)", "claude"]))
        }
        let open = await Task.detached(priority: .utility) { Self.openPaths(uid: uid) }.value

        var items: [CleanItem] = []
        for root in roots {
            items += await Self.scan(root, uid: uid, open: open)
        }
        var notes = [L("Chỉ đề xuất mục của bạn, không chứa socket, không bị process nào mở, và không đổi trong 1 giờ qua. Mục không đổi hơn 3 ngày được chọn sẵn.")]
        if open == nil {
            notes.append(L("Không chạy được lsof — mọi mục được đánh dấu Cân nhắc."))
        }
        return ScanResult(items: items, notes: notes)
    }

    static func scan(_ root: Root, uid: uid_t, open: Set<String>?) async -> [CleanItem] {
        // Split container folders (e.g. /tmp/claude-502/<project>) one level further.
        var candidates: [(url: URL, group: String)] = []
        var looseGroups: [String: URL] = [root.label: root.url]
        for child in root.url.children() {
            let name = child.lastPathComponent
            if root.containers.contains(name), child.isDirectory, Self.owned(child, uid: uid) {
                let group = "\(root.label)/\(name)"
                looseGroups[group] = child
                candidates += child.children().map { ($0, group) }
            } else {
                candidates.append((child, root.label))
            }
        }
        candidates = candidates.filter { Self.eligibleName($0.url.lastPathComponent) && Self.owned($0.url, uid: uid) }

        let infos: [(url: URL, group: String, info: TreeInfo)?] = await concurrentMap(candidates) { c in
            let info = TreeInfo.walk(c.url)
            return info.map { (c.url, c.group, $0) }
        }
        let now = Date()
        // Only open paths under this root matter; keeps the prefix checks below cheap.
        let rootOpen = open?.filter { $0.hasPrefix(root.url.path + "/") }
        let usable = infos.compactMap { $0 }.filter { entry in
            guard !entry.info.hasSpecial, entry.info.size > 0 else { return false }
            guard now.timeIntervalSince(entry.info.newest) > activeWindow else { return false }
            if let rootOpen, Self.isOpen(entry.url, in: rootOpen) { return false }
            return true
        }

        var items: [CleanItem] = []
        var loose: [String: [(URL, TreeInfo)]] = [:]
        for entry in usable {
            if entry.info.size < bundleBelow {
                loose[entry.group, default: []].append((entry.url, entry.info))
                continue
            }
            let stale = Self.isStale(entry.info.newest, now: now) && open != nil
            items.append(CleanItem(
                id: "temp:" + entry.url.path, title: entry.url.lastPathComponent,
                detail: entry.url.path.abbreviatingHome, group: entry.group, size: entry.info.size,
                safety: stale ? .safe : .caution,
                note: stale ? nil : L("Mới dùng gần đây — có thể vẫn cần"),
                action: .delete(entry.url), selectedByDefault: stale, lastModified: entry.info.newest))
        }

        // Small leftovers: one stale bundle per folder (recent small files are not worth the risk).
        for (group, entries) in loose {
            let stale = entries.filter { Self.isStale($0.1.newest, now: now) }
            let size = stale.reduce(Int64(0)) { $0 + $1.1.size }
            guard open != nil, size >= 256 * 1024, let dir = looseGroups[group] else { continue }
            items.append(CleanItem(
                id: "temp-loose:" + dir.path, title: L("File nhỏ không đổi hơn 3 ngày: \(stale.count)"),
                detail: dir.path.abbreviatingHome + "/*", group: group, size: size, safety: .safe, note: nil,
                action: .deletePaths(stale.map(\.0)), selectedByDefault: true,
                lastModified: stale.map(\.1.newest).max()))
        }
        return items
    }

    static func isStale(_ date: Date, now: Date) -> Bool {
        now.timeIntervalSince(date) > Double(staleDays) * 86_400
    }

    static func eligibleName(_ name: String) -> Bool {
        !skipPrefixes.contains(where: name.hasPrefix) && !skipSuffixes.contains(where: name.hasSuffix)
    }

    static func owned(_ url: URL, uid: uid_t) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        let type = st.st_mode & S_IFMT
        return st.st_uid == uid && (type == S_IFREG || type == S_IFDIR)
    }

    /// The per-user temp folder, resolved (/var → /private/var) so it matches lsof output.
    static func userTempDir() -> URL? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count) > 0 else { return nil }
        // realpath keeps /private (URL.resolvingSymlinksInPath strips it).
        guard let real = realpath(buf, nil) else { return nil }
        defer { free(real) }
        let url = URL(fileURLWithPath: String(cString: real))
        return url.isDirectory ? url : nil
    }

    /// Every path the user's processes have open (files, cwd, mapped libraries); nil when lsof fails.
    static func openPaths(uid: uid_t) -> Set<String>? {
        guard let r = try? Shell.runRaw("/usr/sbin/lsof", ["-nPw", "-u", String(uid), "-Fn"],
                                        env: Shell.environment, timeout: 60),
              !r.stdout.isEmpty else { return nil }
        var out = Set<String>()
        for line in r.stdout.split(separator: "\n") where line.hasPrefix("n/") {
            let path = String(line.dropFirst())
            // lsof reports /tmp as /private/tmp already; normalize the /var/folders alias just in case.
            out.insert(path.hasPrefix("/var/") ? "/private" + path : path)
        }
        return out
    }

    static func isOpen(_ url: URL, in open: Set<String>) -> Bool {
        let p = url.path
        if open.contains(p) { return true }
        let prefix = p + "/"
        return open.contains { $0.hasPrefix(prefix) }
    }
}

/// Size, newest mtime and "has a socket/fifo/device" for a tree, in one fts pass.
struct TreeInfo: Sendable {
    var size: Int64 = 0
    var newest: Date = .distantPast
    var hasSpecial = false

    static func walk(_ url: URL) -> TreeInfo? {
        var cPaths: [UnsafeMutablePointer<CChar>?] = [strdup(url.path), nil]
        defer { cPaths.forEach { free($0) } }
        guard let fts = fts_open(&cPaths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return nil }
        defer { fts_close(fts) }

        var info = TreeInfo()
        var newest: Int = 0
        while let ent = fts_read(fts) {
            let kind = Int32(ent.pointee.fts_info)
            if kind == FTS_DP || kind == FTS_DNR || kind == FTS_ERR || kind == FTS_NS { continue }
            guard let st = ent.pointee.fts_statp?.pointee else { continue }
            let type = st.st_mode & S_IFMT
            if type == S_IFSOCK || type == S_IFIFO || type == S_IFCHR || type == S_IFBLK {
                info.hasSpecial = true
                return info
            }
            info.size += Int64(st.st_blocks) * 512
            newest = max(newest, st.st_mtimespec.tv_sec)
        }
        info.newest = Date(timeIntervalSince1970: TimeInterval(newest))
        return info
    }
}
