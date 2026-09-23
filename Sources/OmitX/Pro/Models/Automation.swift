import Foundation

/// Where app data shared by the main window and the background agent is stored.
enum OmitXPaths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.homePath("Library/Application Support")
        return base.appendingPathComponent("OmitX", isDirectory: true)
    }
    static var automation: URL { support.appendingPathComponent("automation.json") }
    static var history: URL { support.appendingPathComponent("history.json") }
    static var chat: URL { support.appendingPathComponent("chat.json") }

    /// UNUserNotificationCenter and SMAppService both require a real .app bundle —
    /// `swift run` has none, so check before calling them.
    static var isBundledApp: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    @discardableResult
    static func ensureSupport() -> Bool {
        (try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)) != nil
    }
}

/// A recurring schedule, in the Mac's time zone.
struct Schedule: Codable, Hashable, Sendable {
    var hour: Int = 9
    var minute: Int = 0
    /// nil = daily. 1...7 = Sunday...Saturday (Calendar's convention).
    var weekday: Int? = nil

    /// The most recent run that should have happened as of `now`.
    func lastOccurrence(before now: Date, calendar: Calendar = .current) -> Date? {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        if let weekday { components.weekday = weekday }
        return calendar.nextDate(after: now, matching: components,
                                 matchingPolicy: .nextTime, direction: .backward)
    }
}

/// An automatic cleanup rule.
struct CleanRule: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String = ""
    var enabled: Bool = true
    var trigger: Trigger = .freeSpaceBelow(20 * 1_000_000_000)
    var query: CleanQuery = .unattended
    var action: Action = .askApproval
    /// Cap on bytes deleted per run; nil = unlimited.
    var maxBytesPerRun: Int64? = nil
    var lastRun: Date? = nil

    enum Trigger: Codable, Hashable, Sendable {
        case schedule(Schedule)
        case freeSpaceBelow(Int64)
    }

    enum Action: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Only send a notification; touch nothing.
        case notifyOnly
        /// Send a notification with "Clean now" / "Skip" buttons.
        case askApproval
        /// Delete right away, then report the result.
        case deleteNow

        var id: String { rawValue }
        var label: String {
            switch self {
            case .notifyOnly: L("Chỉ báo")
            case .askApproval: L("Hỏi trước khi dọn")
            case .deleteNow: L("Dọn ngay")
            }
        }
        /// Whether this action actually deletes files.
        var deletes: Bool { self != .notifyOnly }
    }
}

enum RuleError: LocalizedError {
    case unsafeQuery(Safety)
    case emptyName

    var errorDescription: String? {
        switch self {
        case .unsafeQuery:
            L("Quy tắc tự động chỉ được đụng tới mục mức An toàn. Mục Cân nhắc và Nguy hiểm phải tự xem rồi dọn tay.")
        case .emptyName:
            L("Quy tắc cần có tên.")
        }
    }
}

extension CleanRule {
    /// Hard guardrails for every unattended rule.
    ///
    /// - Only Safe-level items (unless it only notifies and deletes nothing).
    /// - Never runs items that need the admin password: `Shell.runAdmin` must show a dialog,
    ///   which would hang the background agent.
    /// - Skips items held by a running process (Xcode building…).
    func validated() throws -> CleanRule {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw RuleError.emptyName }
        var out = self
        if action.deletes {
            guard query.maxSafety == .safe else { throw RuleError.unsafeQuery(query.maxSafety) }
        }
        out.query.excludeAdmin = true
        out.query.skipBlocked = true
        return out
    }

    /// Trims the list to `maxBytesPerRun`.
    func capped(_ items: [CleanItem]) -> [CleanItem] {
        guard let cap = maxBytesPerRun else { return items }
        var total: Int64 = 0
        return items.prefix { item in
            defer { total += item.size }
            return total + item.size <= cap
        }.map { $0 }
    }
}

/// The whole automation configuration, stored as JSON so both the app and the background agent can read it.
struct AutomationSettings: Codable, Hashable, Sendable {
    var enabled: Bool = false
    /// Warn below this much free space (earlier than macOS, so the disk never fills up by surprise).
    var warnBelowBytes: Int64 = 40 * 1_000_000_000
    /// Trigger `freeSpaceBelow` rules below this much free space.
    var actBelowBytes: Int64 = 20 * 1_000_000_000
    /// How often to check free space, in minutes.
    var pollMinutes: Int = 5
    var rules: [CleanRule] = []
    /// Last low-space warning — so it does not repeat every 5 minutes.
    var lastWarnedAt: Date? = nil

    static func load(from url: URL = OmitXPaths.automation) -> AutomationSettings {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder.omitX.decode(AutomationSettings.self, from: data) else {
            return AutomationSettings()
        }
        return s
    }

    func save(to url: URL = OmitXPaths.automation) throws {
        OmitXPaths.ensureSupport()
        try JSONEncoder.omitX.encode(self).write(to: url, options: .atomic)
    }

    /// Warn again only after 6 hours, to avoid nagging.
    func shouldWarn(freeBytes: Int64, now: Date = Date()) -> Bool {
        guard enabled, freeBytes < warnBelowBytes else { return false }
        guard let last = lastWarnedAt else { return true }
        return now.timeIntervalSince(last) > 6 * 3600
    }
}

extension JSONEncoder {
    static var omitX: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }
}

extension JSONDecoder {
    static var omitX: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
