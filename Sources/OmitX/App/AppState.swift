import Foundation
import SwiftUI
import Observation

enum ScanStatus: Equatable {
    case idle, scanning, done
}

struct ModuleState {
    var status: ScanStatus = .idle
    var result = ScanResult()
    var scannedAt: Date?
}

struct CleanLogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let outcomes: [CleanOutcome]
    var freed: Int64 { outcomes.reduce(0) { $0 + $1.freed } }
    var failures: [CleanOutcome] { outcomes.filter { $0.error != nil } }
}

@MainActor
@Observable
final class AppState {
    // MARK: Settings (persisted in UserDefaults via EngineSettings)
    var deleteMode: DeleteMode { didSet { settings.save() } }
    var projectRoots: [URL] { didSet { settings.save() } }
    var projectMaxDepth: Int { didSet { settings.save() } }
    var staleDays: Int { didSet { settings.save() } }

    /// Snapshot of the settings to hand to the UI-free core (CleanEngine, the background agent).
    var settings: EngineSettings {
        EngineSettings(deleteMode: deleteMode, projectRoots: projectRoots,
                       projectMaxDepth: projectMaxDepth, staleDays: staleDays)
    }

    // MARK: Scan state
    var states: [String: ModuleState] = [:]
    var selection: Set<String> = []
    var volume = DiskUsage.volumeInfo()

    // MARK: Clean state
    var isCleaning = false
    var cleanProgress: (done: Int, total: Int, current: String) = (0, 0, "")
    var log: [CleanLogEntry] = []
    var lastLog: CleanLogEntry?

    init() {
        let s = EngineSettings.load()
        deleteMode = s.deleteMode
        projectRoots = s.projectRoots
        projectMaxDepth = s.projectMaxDepth
        staleDays = s.staleDays
    }

    nonisolated static func defaultProjectRoots() -> [URL] { EngineSettings.defaultProjectRoots() }

    // MARK: Modules
    var cleanModules: [any CleanModule] { CleanEngine.cleanModules() }

    var projectModule: ProjectModule { CleanEngine.projectModule(settings) }

    var allModules: [any CleanModule] { CleanEngine.allModules(settings) }

    func module(_ id: String) -> (any CleanModule)? { CleanEngine.module(id, settings: settings) }

    func state(_ id: String) -> ModuleState { states[id] ?? ModuleState() }

    func items(_ moduleID: String) -> [CleanItem] { state(moduleID).result.items }

    // MARK: Scan
    func scan(_ moduleID: String) async {
        guard let module = module(moduleID), state(moduleID).status != .scanning else { return }
        states[moduleID, default: ModuleState()].status = .scanning
        let result = await Task.detached(priority: .userInitiated) { await module.scan() }.value
        // Drop the module's old selection and apply the new default selection
        let oldIDs = Set(items(moduleID).map(\.id))
        selection.subtract(oldIDs)
        var sorted = result
        // Largest group first; within a group, sort by size
        var groupTotals: [String: Int64] = [:]
        for item in result.items { groupTotals[item.group, default: 0] += item.size }
        sorted.items.sort {
            let (ga, gb) = (groupTotals[$0.group] ?? 0, groupTotals[$1.group] ?? 0)
            if $0.group != $1.group { return ga != gb ? ga > gb : $0.group < $1.group }
            return $0.size > $1.size
        }
        states[moduleID] = ModuleState(status: .done, result: sorted, scannedAt: Date())
        for item in sorted.items where item.selectedByDefault { selection.insert(item.id) }
        volume = DiskUsage.volumeInfo()
    }

    func scanAll(includeProjects: Bool = true) async {
        let ids = (includeProjects ? allModules : cleanModules).map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { await self.scan(id) } }
        }
    }

    var isScanningAny: Bool { states.values.contains { $0.status == .scanning } }

    // MARK: Selection
    func isSelected(_ item: CleanItem) -> Bool { selection.contains(item.id) }

    func toggle(_ item: CleanItem) {
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    func setSelected(_ items: [CleanItem], _ on: Bool) {
        if on { selection.formUnion(items.map(\.id)) } else { selection.subtract(items.map(\.id)) }
    }

    /// Selected items across all modules, deduplicated by ID, dropping items nested inside another selected item.
    func selectedItems(in moduleIDs: [String]? = nil) -> [CleanItem] {
        let ids = moduleIDs ?? allModules.map(\.id)
        var seen = Set<String>()
        let all = ids.flatMap { items($0) }.filter { selection.contains($0.id) && seen.insert($0.id).inserted }
        return Self.removeNested(all)
    }

    nonisolated static func removeNested(_ items: [CleanItem]) -> [CleanItem] {
        CleanItem.removeNested(items)
    }

    func selectedSize(in moduleIDs: [String]? = nil) -> Int64 {
        selectedItems(in: moduleIDs).reduce(0) { $0 + $1.size }
    }

    /// Reclaimable total for one module (deduplicated).
    func totalSize(_ moduleID: String) -> Int64 {
        Self.removeNested(items(moduleID)).reduce(0) { $0 + $1.size }
    }

    /// Grand total of everything scanned, counting each ID once.
    var grandTotal: Int64 {
        var seen = Set<String>()
        let all = allModules.flatMap { items($0.id) }.filter { seen.insert($0.id).inserted }
        return Self.removeNested(all).reduce(0) { $0 + $1.size }
    }

    // MARK: Clean
    func clean(_ items: [CleanItem]) async {
        guard !isCleaning, !items.isEmpty else { return }
        isCleaning = true
        cleanProgress = (0, items.count, "")
        // Commands (docker, brew…) run sequentially; file deletions too, so progress is easy to follow.
        let outcomes = await CleanEngine.execute(items, mode: deleteMode) { done, total, item in
            Task { @MainActor in self.cleanProgress = (done, total, item.title) }
        }
        for outcome in outcomes where outcome.error == nil { selection.remove(outcome.item.id) }
        cleanProgress.done = items.count
        let entry = CleanLogEntry(date: Date(), outcomes: outcomes)
        log.insert(entry, at: 0)
        lastLog = entry
        isCleaning = false

        // Rescan the affected modules
        let affected = Set(allModules.filter { m in self.items(m.id).contains { i in items.contains { $0.id == i.id } } }.map(\.id))
        for id in affected { await scan(id) }
        volume = DiskUsage.volumeInfo()
    }
}
