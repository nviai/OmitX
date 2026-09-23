import Foundation

struct IDEModule: CleanModule {
    let id = "ide"
    let title = "IDE & Editor"
    let icon = "macwindow.on.rectangle"
    let summary = L("VS Code, Cursor, Windsurf, JetBrains, Zed, Sublime; extension cũ; cache app Electron (Slack, Postman...)")

    /// (folder name in Application Support, display name, extensions folder, process name)
    static let vscodeFamily: [(String, String, String?, String)] = [
        ("Code", "VS Code", ".vscode/extensions", "Visual Studio Code"),
        ("Code - Insiders", "VS Code Insiders", ".vscode-insiders/extensions", "Code - Insiders"),
        ("Cursor", "Cursor", ".cursor/extensions", "Cursor"),
        ("Windsurf", "Windsurf", ".windsurf/extensions", "Windsurf"),
        ("VSCodium", "VSCodium", ".vscode-oss/extensions", "VSCodium"),
        ("Kiro", "Kiro", ".kiro/extensions", "Kiro"),
        ("Trae", "Trae", ".trae/extensions", "Trae"),
        ("Antigravity", "Antigravity", ".antigravity/extensions", "Antigravity"),
    ]

    static let electronCacheDirs = ["Cache", "CachedData", "CachedExtensionVSIXs", "CachedProfilesData", "Code Cache",
                                    "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "ShaderCache",
                                    "Service Worker/CacheStorage", "Service Worker/ScriptCache", "logs", "Crashpad/completed"]

    func scan() async -> ScanResult {
        var specs: [PathSpec] = []
        let appSupport = URL.homePath("Library/Application Support")

        for (dir, name, extDir, process) in Self.vscodeFamily {
            let base = appSupport.appendingPathComponent(dir)
            guard base.exists else { continue }
            for sub in Self.electronCacheDirs {
                specs.append(PathSpec(base.appendingPathComponent(sub), "\(name) · \(sub)", group: name, blocking: [process]))
            }
            specs.append(PathSpec(base.appendingPathComponent("User/workspaceStorage"), "\(name) · workspaceStorage",
                                  group: name, safety: .caution,
                                  note: L("Trạng thái từng workspace (tab mở, lịch sử chat AI của Cursor/Copilot...). Có thể rất lớn."),
                                  selected: false, blocking: [process]))
            specs.append(PathSpec(base.appendingPathComponent("User/History"), "\(name) · Local History", group: name,
                                  safety: .caution, note: L("Lịch sử chỉnh sửa file cục bộ (Timeline)"), selected: false))
            // Old extension versions already marked obsolete
            if let extDir {
                let extRoot = URL.homePath(extDir)
                for obsolete in Self.obsoleteExtensions(in: extRoot) {
                    specs.append(PathSpec(obsolete, L("Extension cũ: \(obsolete.lastPathComponent)"), group: "\(name) extensions",
                                          note: L("Phiên bản cũ đã được thay thế")))
                }
            }
        }
        // Editors' update caches
        for sub in ["com.microsoft.VSCode.ShipIt", "com.todesktop.230313mzl4w4u92.ShipIt", "com.exafunction.windsurf.ShipIt",
                    "Cursor", "cursor-updater", "vscode-cpptools"] {
            specs.append(PathSpec(home: "Library/Caches/\(sub)", "Updater/cache: \(sub)", group: L("Editor updater cache")))
        }

        // JetBrains
        let jb = "JetBrains"
        specs += ScanKit.children(of: .homePath("Library/Caches/JetBrains"), group: jb, note: L("IDE sẽ index lại"),
                                  title: { "\($0.lastPathComponent) cache" })
        specs += ScanKit.children(of: .homePath("Library/Logs/JetBrains"), group: jb, title: { "\($0.lastPathComponent) logs" })
        specs += Self.oldVersions(in: .homePath("Library/Application Support/JetBrains"), group: jb)
        specs.append(PathSpec(home: "Library/Application Support/JetBrains/Toolbox/download", L("Toolbox downloads"), group: jb))

        // Other editors
        let other = L("Editor khác")
        specs += [
            PathSpec(home: "Library/Caches/Zed", "Zed cache", group: other),
            PathSpec(home: "Library/Logs/Zed", "Zed logs", group: other),
            PathSpec(home: "Library/Caches/com.sublimetext.4", "Sublime Text cache", group: other),
            PathSpec(home: "Library/Caches/com.sublimemerge", "Sublime Merge cache", group: other),
            PathSpec(home: "Library/Caches/com.github.GitHubClient", "GitHub Desktop cache", group: other),
            PathSpec(home: "Library/Caches/com.fournova.Tower3", "Tower cache", group: other),
            PathSpec(home: "Library/Caches/com.axosoft.gitkraken", "GitKraken cache", group: other),
        ]

        // Electron apps commonly used for development
        let electron = L("App Electron (Slack, Postman...)")
        for (dir, name) in [("Slack", "Slack"), ("discord", "Discord"), ("Postman", "Postman"), ("Insomnia", "Insomnia"),
                            ("Notion", "Notion"), ("Figma", "Figma"), ("Microsoft Teams", "Teams"),
                            ("Claude", "Claude"), ("ChatGPT", "ChatGPT"), ("Linear", "Linear"), ("Bruno", "Bruno")] {
            let base = appSupport.appendingPathComponent(dir)
            guard base.exists else { continue }
            for sub in ["Cache", "Code Cache", "GPUCache", "Service Worker/CacheStorage", "DawnCache", "DawnGraphiteCache", "logs"] {
                specs.append(PathSpec(base.appendingPathComponent(sub), "\(name) · \(sub)", group: electron, blocking: [name]))
            }
        }

        let items = await ScanKit.measure(specs, minSize: 512 * 1024)
        return ScanResult(items: items, notes: [L("Nên tắt editor trước khi xoá cache của nó.")])
    }

    /// VS Code records old extensions in the `.obsolete` file (JSON {"folder": true}).
    static func obsoleteExtensions(in root: URL) -> [URL] {
        let file = root.appendingPathComponent(".obsolete")
        guard let data = try? Data(contentsOf: file),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return dict.keys.map { root.appendingPathComponent($0) }.filter(\.exists)
    }

    /// "IntelliJIdea2024.1", "IntelliJIdea2025.2" → the older ones.
    static func oldVersions(in dir: URL, group: String) -> [PathSpec] {
        var byProduct: [String: [URL]] = [:]
        for child in dir.children(includeHidden: false) {
            let name = child.lastPathComponent
            guard let idx = name.firstIndex(where: \.isNumber) else { continue }
            byProduct[String(name[..<idx]), default: []].append(child)
        }
        var specs: [PathSpec] = []
        for (_, list) in byProduct where list.count > 1 {
            let sorted = list.sorted { ScanKit.versionLess($0.lastPathComponent, $1.lastPathComponent) }
            for old in sorted.dropLast() {
                specs.append(PathSpec(old, L("Cấu hình \(old.lastPathComponent) (bản cũ)"), group: group, safety: .caution,
                                      note: L("Settings/plugin của phiên bản IDE cũ"), selected: true))
            }
        }
        return specs
    }
}
