import Foundation

/// Describes "what to clean" without a UI and without listing individual items.
///
/// Chat emits a `CleanQuery`, automation rules store one, the CLI accepts one —
/// and all of them go through exactly one resolver (`CleanEngine.resolve`). The language model
/// never sees the item list; it only describes conditions.
struct CleanQuery: Codable, Hashable, Sendable {
    /// Module IDs to consider (xcode, simulator, docker…); empty = all modules.
    var modules: [String] = []
    /// Subgroup names to consider; empty = all groups.
    var groups: [String] = []
    /// Highest safety level allowed to be touched.
    var maxSafety: Safety = .safe
    /// Skip items smaller than this (bytes).
    var minSize: Int64 = 0
    /// Only items untouched for more than N days. Items without a timestamp are excluded.
    var staleDays: Int? = nil
    /// Exclude items needing admin rights — background runs cannot show a password dialog.
    var excludeAdmin: Bool = true
    /// Skip items held by a running process (Xcode building, an emulator running…).
    var skipBlocked: Bool = true
    /// Keep only the N largest items.
    var limit: Int? = nil

    /// The strictly safe query used for every unattended background operation.
    static let unattended = CleanQuery(maxSafety: .safe, excludeAdmin: true, skipBlocked: true)

    /// Whether an item matches. `running` is the set of running process names,
    /// passed in so `pgrep` is not called for every item.
    func matches(_ item: CleanItem, running: Set<String> = []) -> Bool {
        guard item.safety <= maxSafety else { return false }
        guard item.size >= minSize else { return false }
        if !groups.isEmpty,
           !groups.contains(where: { $0.caseInsensitiveCompare(item.group) == .orderedSame }) { return false }
        if excludeAdmin, item.needsAdmin { return false }
        if skipBlocked, item.blockingProcesses.contains(where: { running.contains($0) }) { return false }
        if let days = staleDays {
            guard let touched = item.lastModified else { return false }
            guard touched < Date().addingTimeInterval(-Double(days) * 86_400) else { return false }
        }
        return true
    }

    /// Which modules must be scanned to answer this query.
    func moduleIDs(among all: [String]) -> [String] {
        modules.isEmpty ? all : all.filter { modules.contains($0) }
    }
}
