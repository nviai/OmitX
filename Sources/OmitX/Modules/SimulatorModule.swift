import Foundation

struct SimulatorModule: CleanModule {
    let id = "simulator"
    let title = "iOS Simulator"
    let icon = "iphone.gen3"
    let summary = L("Simulator runtime (iOS 17/18/26...), thiết bị simulator, dyld cache")

    func scan() async -> ScanResult {
        guard Shell.has("xcrun") else {
            return ScanResult(notes: [L("Chưa cài Xcode / Command Line Tools.")])
        }
        async let runtimes = scanRuntimes()
        async let devices = scanDevices()
        let caches = await ScanKit.measure([
            PathSpec(home: "Library/Developer/CoreSimulator/Caches", "CoreSimulator cache (dyld)", group: L("Cache"),
                     note: L("Tạo lại khi boot simulator")),
            PathSpec(home: "Library/Logs/CoreSimulator", "CoreSimulator logs", group: L("Cache")),
        ])
        let (r, d) = await (runtimes, devices)
        return ScanResult(items: r.items + d.items + caches, notes: r.notes + d.notes)
    }

    private func scanRuntimes() async -> ScanResult {
        guard let r = try? await Shell.runAsync("xcrun", ["simctl", "runtime", "list", "-j"], timeout: 60), r.ok,
              let json = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: [String: Any]]
        else { return ScanResult(notes: [L("Không đọc được danh sách simulator runtime.")]) }

        let iso = ISO8601DateFormatter()
        var items: [CleanItem] = []
        for (key, rt) in json {
            guard (rt["deletable"] as? Bool) ?? true else { continue }
            let identifier = rt["identifier"] as? String ?? key
            let runtimeId = rt["runtimeIdentifier"] as? String ?? ""
            let version = rt["version"] as? String ?? ""
            let build = rt["build"] as? String ?? ""
            let size = (rt["sizeBytes"] as? NSNumber)?.int64Value ?? 0
            let lastUsed = (rt["lastUsedAt"] as? String).flatMap { iso.date(from: $0) }
            let platform = Self.platformName(runtimeId).split(separator: " ").first.map(String.init) ?? "Runtime"
            let lastUsedText = lastUsed.map { L("Dùng lần cuối: \($0.formatted(date: .abbreviated, time: .omitted)).") }
                ?? L("Chưa từng được dùng.")
            let note = L("Xoá bằng simctl. Tải lại trong Xcode → Settings → Components.") + " " + lastUsedText
            var item = ScanKit.commandItem(
                id: "simruntime:\(identifier)",
                title: "\(platform) \(version) (\(build))",
                group: "Simulator Runtimes",
                command: ShellCommand(executable: "xcrun", arguments: ["simctl", "runtime", "delete", identifier]),
                size: size, safety: .caution, note: note, selected: false,
                detail: rt["state"] as? String)
            item.lastModified = lastUsed
            items.append(item)
        }
        items.sort { ScanKit.versionLess($0.title, $1.title) }
        return ScanResult(items: items)
    }

    private func scanDevices() async -> ScanResult {
        guard let r = try? await Shell.runAsync("xcrun", ["simctl", "list", "devices", "-j"], timeout: 60), r.ok,
              let json = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any],
              let byRuntime = json["devices"] as? [String: [[String: Any]]]
        else { return ScanResult(notes: [L("Không đọc được danh sách simulator.")]) }

        struct Dev: Sendable { let udid, name, runtime, state: String; let available: Bool; let dir: URL }
        var devs: [Dev] = []
        var known = Set<String>()
        let devicesRoot = URL.homePath("Library/Developer/CoreSimulator/Devices")
        for (runtime, list) in byRuntime {
            for d in list {
                guard let udid = d["udid"] as? String else { continue }
                known.insert(udid)
                let dir = (d["dataPath"] as? String).map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
                    ?? devicesRoot.appendingPathComponent(udid)
                devs.append(Dev(udid: udid, name: d["name"] as? String ?? udid,
                                runtime: Self.platformName(runtime),
                                state: d["state"] as? String ?? "",
                                available: d["isAvailable"] as? Bool ?? true, dir: dir))
            }
        }

        let items: [CleanItem] = await concurrentMap(devs) { dev in
            let size = DiskUsage.size(of: dev.dir)
            var item = ScanKit.commandItem(
                id: "simdevice:\(dev.udid)",
                title: "\(dev.name) — \(dev.runtime)",
                group: dev.available ? L("Thiết bị Simulator") : L("Simulator không khả dụng"),
                command: ShellCommand(executable: "xcrun", arguments: ["simctl", "delete", dev.udid]),
                size: size,
                safety: dev.available ? .caution : .safe,
                note: dev.available ? L("Mất app + dữ liệu đã cài trong simulator này (\(dev.state))")
                                    : L("Runtime đã bị gỡ — simulator này không dùng được nữa"),
                detail: dev.udid)
            item.lastModified = dev.dir.modificationDate
            return item
        }

        // Orphaned device folders that simctl no longer knows about
        let orphans = devicesRoot.children(includeHidden: false).filter {
            $0.isDirectory && !known.contains($0.lastPathComponent) && UUID(uuidString: $0.lastPathComponent) != nil
        }
        let orphanItems = await ScanKit.measure(orphans.map {
            PathSpec($0, L("Device mồ côi \($0.lastPathComponent.prefix(8))…"), group: L("Simulator không khả dụng"),
                     note: L("Không còn trong danh sách simctl"))
        })
        return ScanResult(items: items + orphanItems)
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-18-3" → "iOS 18.3"
    static func platformName(_ runtimeId: String) -> String {
        guard let last = runtimeId.split(separator: ".").last else { return runtimeId }
        let parts = last.split(separator: "-")
        guard let os = parts.first else { return String(last) }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? String(os) : "\(os) \(version)"
    }
}
