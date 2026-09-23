import Foundation

/// Result of a rule's dry run — used both for the preview while editing and for real runs.
struct RulePlan: Sendable {
    var rule: CleanRule
    var items: [CleanItem]
    var bytes: Int64 { items.reduce(0) { $0 + $1.size } }
    var isEmpty: Bool { items.isEmpty }
}

/// One run of a rule, recorded for the history.
struct RuleRun: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var ruleID: UUID
    var ruleName: String
    var date: Date
    var matched: Int
    var bytes: Int64
    var action: CleanRule.Action
    /// Whether anything was actually deleted (false for askApproval runs not yet approved).
    var executed: Bool
    var freed: Int64
    var errors: [String]
}

/// Run history — `AppState.log` lives only in memory, so the background agent needs its own store.
struct RunHistory: Codable, Sendable {
    var runs: [RuleRun] = []
    static let limit = 200

    static func load(from url: URL = OmitXPaths.history) -> RunHistory {
        guard let data = try? Data(contentsOf: url),
              let h = try? JSONDecoder.omitX.decode(RunHistory.self, from: data) else { return RunHistory() }
        return h
    }

    mutating func append(_ run: RuleRun) {
        runs.insert(run, at: 0)
        if runs.count > Self.limit { runs.removeLast(runs.count - Self.limit) }
    }

    func save(to url: URL = OmitXPaths.history) throws {
        OmitXPaths.ensureSupport()
        try JSONEncoder.omitX.encode(self).write(to: url, options: .atomic)
    }
}
