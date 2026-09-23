import Foundation

/// UI-independent scan & clean core, shared by the app, the CLI, chat and automation rules.
///
/// `AppState` is a @MainActor wrapper around this; the background agent calls these functions directly.
enum CleanEngine {
    // MARK: Module

    /// The fixed module list — a single source of truth so the app and CLI cannot drift apart.
    static func cleanModules() -> [any CleanModule] {
        [XcodeModule(), SimulatorModule(), AndroidModule(), FlutterModule(), JavaScriptModule(), PythonModule(),
         LanguagesModule(), DockerModule(), HomebrewModule(), IDEModule(), AIAgentModule(), TempModule(), SystemModule()]
    }

    static func projectModule(_ settings: EngineSettings) -> ProjectModule {
        ProjectModule(roots: settings.projectRoots, maxDepth: settings.projectMaxDepth, staleDays: settings.staleDays)
    }

    static func allModules(_ settings: EngineSettings) -> [any CleanModule] {
        cleanModules() + [projectModule(settings)]
    }

    static func module(_ id: String, settings: EngineSettings) -> (any CleanModule)? {
        allModules(settings).first { $0.id == id }
    }

    static func allModuleIDs(_ settings: EngineSettings) -> [String] {
        allModules(settings).map(\.id)
    }

    // MARK: Scanning

    /// Scans the given modules (empty = all) in parallel. Never touches the UI.
    static func scan(_ ids: [String] = [], settings: EngineSettings) async -> [String: ScanResult] {
        let wanted = allModules(settings).filter { ids.isEmpty || ids.contains($0.id) }
        var out: [String: ScanResult] = [:]
        await withTaskGroup(of: (String, ScanResult).self) { group in
            for m in wanted {
                group.addTask { (m.id, await m.scan()) }
            }
            for await (id, result) in group { out[id] = result }
        }
        return out
    }

    // MARK: Query resolution

    /// Names of running processes among those mentioned by the scan results.
    /// Calls `pgrep` once per name instead of once per item.
    static func runningBlockers(in results: [String: ScanResult]) async -> Set<String> {
        let names = Set(results.values.flatMap { $0.items.flatMap(\.blockingProcesses) })
        guard !names.isEmpty else { return [] }
        return await Task.detached(priority: .utility) {
            Set(names.filter { Shell.isRunning($0) })
        }.value
    }

    /// Turns a query into concrete items: filter by the conditions, drop nested items,
    /// sort by size descending, then cut to `limit`.
    static func resolve(_ query: CleanQuery, in results: [String: ScanResult],
                        running: Set<String> = []) -> [CleanItem] {
        var seen = Set<String>()
        let candidates = results
            .filter { query.modules.isEmpty || query.modules.contains($0.key) }
            .flatMap(\.value.items)
            .filter { seen.insert($0.id).inserted && query.matches($0, running: running) }
        let deduped = CleanItem.removeNested(candidates).sorted { $0.size > $1.size }
        if let limit = query.limit, limit < deduped.count { return Array(deduped.prefix(limit)) }
        return deduped
    }

    /// Scan and resolve in one step — the path used by automation rules and chat.
    static func find(_ query: CleanQuery, settings: EngineSettings) async -> (items: [CleanItem], scanned: [String: ScanResult]) {
        let ids = query.moduleIDs(among: allModuleIDs(settings))
        let results = await scan(ids, settings: settings)
        let running = query.skipBlocked ? await runningBlockers(in: results) : []
        return (resolve(query, in: results, running: running), results)
    }

    // MARK: Execution

    /// Cleans sequentially, reporting progress via the closure. Never throws — errors live in each `CleanOutcome`.
    @discardableResult
    static func execute(_ items: [CleanItem], mode: DeleteMode,
                        progress: @Sendable (Int, Int, CleanItem) -> Void = { _, _, _ in }) async -> [CleanOutcome] {
        var outcomes: [CleanOutcome] = []
        outcomes.reserveCapacity(items.count)
        for (i, item) in items.enumerated() {
            progress(i, items.count, item)
            outcomes.append(await Cleaner.clean(item, mode: mode))
        }
        return outcomes
    }
}

extension Collection where Element == CleanItem {
    /// Total size, excluding items nested inside other items.
    var reclaimable: Int64 {
        CleanItem.removeNested(Array(self)).reduce(0) { $0 + $1.size }
    }
}
