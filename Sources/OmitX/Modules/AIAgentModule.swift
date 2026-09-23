import Foundation

/// Terminal coding agents (Claude Code, Codex, Gemini CLI, opencode, Cursor CLI, Copilot CLI…).
/// Caches and logs are safe; session transcripts are listed per project / per month so the user
/// (or a rule with staleDays) can drop only the old ones. Config, auth, skills and memory are never touched.
struct AIAgentModule: CleanModule {
    let id = "ai-agents"
    let title = "AI Coding Agents"
    let icon = "sparkles.rectangle.stack"
    let summary = L("Claude Code, Codex, Gemini CLI, opencode, Cursor CLI, Copilot CLI: cache, log, lịch sử phiên cũ")

    /// Files written in the last few minutes may belong to a session that is still running.
    static let activeWindow: TimeInterval = 10 * 60

    func scan() async -> ScanResult {
        var specs: [PathSpec] = []
        let historyNote = L("Lịch sử hội thoại — xoá thì không resume được phiên cũ")

        // Claude Code
        let claude = "Claude Code"
        specs += [
            PathSpec(home: "Library/Caches/claude-cli-nodejs", "Claude Code · CLI cache", group: claude),
            PathSpec(home: ".claude/cache", "Claude Code · cache", group: claude),
            PathSpec(home: ".claude/paste-cache", "Claude Code · paste-cache", group: claude),
            PathSpec(home: ".claude/shell-snapshots", "Claude Code · shell-snapshots", group: claude),
            PathSpec(home: ".claude/debug", "Claude Code · debug logs", group: claude),
            PathSpec(home: ".claude/statsig", "Claude Code · statsig", group: claude),
            PathSpec(home: ".claude/telemetry", "Claude Code · telemetry", group: claude),
            PathSpec(home: ".claude/todos", "Claude Code · todos", group: claude, safety: .caution,
                     note: L("Danh sách todo của các phiên cũ"), selected: false),
            PathSpec(home: ".claude/file-history", "Claude Code · file-history", group: claude, safety: .caution,
                     note: L("Checkpoint dùng cho /rewind"), selected: false),
        ]

        // Codex CLI
        let codex = "Codex CLI"
        specs += [
            PathSpec(home: ".codex/log", "Codex · log", group: codex),
            PathSpec(home: ".codex/tmp", "Codex · tmp", group: codex),
            PathSpec(home: ".codex/archived_sessions", "Codex · archived sessions", group: codex, safety: .caution,
                     note: historyNote, selected: false),
        ]

        // Gemini CLI / Antigravity / Qwen Code (a Gemini CLI fork)
        let gemini = "Gemini CLI"
        specs += [
            PathSpec(home: ".gemini/tmp", "Gemini CLI · tmp (chats, checkpoints, logs)", group: gemini, safety: .caution,
                     note: historyNote, selected: false),
            PathSpec(home: ".gemini/antigravity/conversations", "Antigravity · conversations", group: gemini,
                     safety: .caution, note: historyNote, selected: false),
            PathSpec(home: ".gemini/antigravity/implicit", "Antigravity · implicit context", group: gemini,
                     safety: .caution, selected: false),
            PathSpec(home: ".qwen/tmp", "Qwen Code · tmp", group: gemini, safety: .caution, note: historyNote, selected: false),
        ]

        // opencode
        let opencode = "opencode"
        specs += [
            PathSpec(home: ".cache/opencode", "opencode · cache", group: opencode, note: L("Provider/plugin sẽ được tải lại")),
            PathSpec(home: ".local/share/opencode/log", "opencode · log", group: opencode),
            PathSpec(home: ".local/share/opencode/snapshot", "opencode · snapshot", group: opencode, safety: .caution,
                     note: L("Snapshot dùng để undo thay đổi của agent"), selected: false),
            PathSpec(home: ".local/share/opencode/storage", "opencode · sessions", group: opencode, safety: .caution,
                     note: historyNote, selected: false),
        ]

        // Other agents
        let other = L("Agent khác")
        specs += [
            PathSpec(home: ".cursor/chats", "Cursor CLI · chats", group: other, safety: .caution, note: historyNote,
                     selected: false),
            PathSpec(home: ".copilot/logs", "Copilot CLI · logs", group: other),
            PathSpec(home: ".copilot/session-state", "Copilot CLI · sessions", group: other, safety: .caution,
                     note: historyNote, selected: false),
        ]

        var items = await ScanKit.measure(specs, minSize: 256 * 1024)
        items += await Self.claudeTranscripts(group: claude, note: historyNote)
        items += await Self.codexSessions(group: codex, note: historyNote)
        return ScanResult(items: items, notes: [
            L("Cấu hình, đăng nhập, skills, plugins và memory của các agent không bao giờ bị xoá."),
        ])
    }

    /// One item per project in ~/.claude/projects: the session transcripts (*.jsonl and their
    /// sidecar folders), keeping `memory/` and anything touched in the last few minutes.
    static func claudeTranscripts(group: String, note: String) async -> [CleanItem] {
        let root = URL.homePath(".claude/projects")
        let cutoff = Date().addingTimeInterval(-activeWindow)
        let projects = root.children(includeHidden: false).filter(\.isDirectory)
        let items: [CleanItem?] = await concurrentMap(projects) { project in
            let children = project.children()
            let transcripts = children.filter { $0.pathExtension == "jsonl" }
            // A session = <id>.jsonl + optional <id>/ folder; the .jsonl is what gets appended to.
            let active = Set(transcripts.filter { ($0.modificationDate ?? .distantPast) >= cutoff }
                .map { $0.deletingPathExtension().lastPathComponent })
            let paths = children.filter { url in
                let stem = url.deletingPathExtension().lastPathComponent
                guard url.pathExtension == "jsonl" || (url.isDirectory && UUID(uuidString: stem) != nil) else { return false }
                return !active.contains(stem)
            }
            guard !paths.isEmpty else { return nil }
            let size = DiskUsage.size(ofPaths: paths.map(\.path))
            guard size >= 256 * 1024 else { return nil }
            let sessions = paths.filter { $0.pathExtension == "jsonl" }.count
            return CleanItem(
                id: "claude-transcripts:" + project.standardizedFileURL.path,
                title: L("Phiên Claude Code: \(Self.projectName(project.lastPathComponent)) (\(sessions))"),
                detail: project.path.abbreviatingHome + "/*.jsonl",
                group: group, size: size, safety: .caution, note: note, action: .deletePaths(paths),
                selectedByDefault: false, lastModified: paths.compactMap(\.modificationDate).max())
        }
        return items.compactMap { $0 }
    }

    /// "-Users-me-Workspaces-App" → "Workspaces-App" (the folder name is the cwd with "/" → "-").
    static func projectName(_ encoded: String) -> String {
        let home = NSHomeDirectory().replacingOccurrences(of: "/", with: "-")
        guard encoded.hasPrefix(home) else { return encoded }
        let rest = encoded.dropFirst(home.count).drop(while: { $0 == "-" })
        return rest.isEmpty ? "~" : String(rest)
    }

    /// One item per month in ~/.codex/sessions/YYYY/MM/DD. The folders' own mtimes only move when
    /// a file is added, so the newest rollout file decides whether the month is still in use.
    static func codexSessions(group: String, note: String) async -> [CleanItem] {
        let root = URL.homePath(".codex/sessions")
        let cutoff = Date().addingTimeInterval(-activeWindow)
        var specs: [PathSpec] = []
        var touched: [URL: Date] = [:]
        for year in root.children(includeHidden: false) where year.isDirectory {
            for month in year.children(includeHidden: false) where month.isDirectory {
                let files = month.children(includeHidden: false).flatMap { day in
                    day.isDirectory ? day.children(includeHidden: false) : [day]
                }
                let latest = files.compactMap(\.modificationDate).max() ?? month.modificationDate ?? .distantPast
                guard latest < cutoff else { continue }
                touched[month] = latest
                specs.append(PathSpec(month, "Codex · sessions \(year.lastPathComponent)/\(month.lastPathComponent)",
                                      group: group, safety: .caution, note: note, selected: false))
            }
        }
        return await ScanKit.measure(specs, minSize: 256 * 1024).map { item in
            var item = item
            if let url = item.path { item.lastModified = touched[url] ?? item.lastModified }
            return item
        }
    }
}
