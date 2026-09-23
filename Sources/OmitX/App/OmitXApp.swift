import SwiftUI
import AppKit

@main
enum Main {
    static func main() {
        // `OmitX --scan-report [module...]`: scan and print the results only; deletes NOTHING.
        if CommandLine.arguments.contains("--scan-report") {
            ScanReport.run(CommandLine.arguments.drop { $0 != "--scan-report" }.dropFirst().map { $0 })
            return
        }
        // `OmitX --agent`: background agent that watches free space and runs automation rules.
        if CommandLine.arguments.contains("--agent") {
            MainActor.assumeIsolated { Pro.installIfAvailable(); Pro.runAgent?() }
            return
        }
        // `OmitX --license <command>`: exercise the licensing flow from a terminal (see LicenseCLI).
        if let i = CommandLine.arguments.firstIndex(of: "--license") {
            let rest = Array(CommandLine.arguments[(i + 1)...])
            MainActor.assumeIsolated { LicenseCLI.run(rest) }
            return
        }
        // The screenshot tooling below exists for documentation and the website, so it is left out
        // of release builds entirely — a shipped app has no business opening windows off a CLI flag.
        // Build it with `./scripts/build-app.sh --debug` when screenshots are needed.
#if DEBUG
        // `OmitX --snapshot out.png [dashboard|<moduleID>]`: render the UI to a PNG; deletes nothing.
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let rest = Array(CommandLine.arguments[(i + 1)...])
            MainActor.assumeIsolated { Snapshot.run(out: rest[0], target: rest.count > 1 ? rest[1] : "dashboard") }
            return
        }
        // `OmitX --window-shot out.png <target>`: open a real window and capture it; deletes nothing.
        //   target: dashboard | settings[:license|automation] | uninstaller[:App name] | analyzer[:/some/path] | <moduleID>
        //   env: SHOT_APPEARANCE=light|dark, SHOT_DELAY=<s>, SHOT_SIZE=<w>x<h>,
        //        SHOT_CHAT="<prompt>" (sends a real prompt in Propose mode — preselects, never deletes)
        if let i = CommandLine.arguments.firstIndex(of: "--window-shot"), i + 1 < CommandLine.arguments.count {
            let rest = Array(CommandLine.arguments[(i + 1)...])
            MainActor.assumeIsolated { WindowShot.run(out: rest[0], target: rest.count > 1 ? rest[1] : "dashboard") }
            return
        }
#endif
        OmitXApp.main()
    }
}

#if DEBUG
/// Initial values for the --window-shot debug mode.
enum DebugLaunch {
    nonisolated(unsafe) static var analyzerFolder: URL?
    nonisolated(unsafe) static var uninstallerApp: String?
    /// Prompt the assistant sends by itself once, for marketing screenshots of a real conversation.
    nonisolated(unsafe) static var chatPrompt: String?
}

/// Opens a real window (List/Table are drawn by AppKit) and captures that window.
@MainActor
enum WindowShot {
    static func run(out: String, target: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Pro.installIfAvailable()
        let state = AppState()
        let parts = target.split(separator: ":", maxSplits: 1).map(String.init)
        let selection: SidebarItem
        switch parts[0] {
        case "dashboard": selection = .dashboard
        case "uninstaller":
            selection = .uninstaller
            DebugLaunch.uninstallerApp = parts.count > 1 ? parts[1] : nil
        case "analyzer":
            selection = .analyzer
            DebugLaunch.analyzerFolder = parts.count > 1 ? URL(fileURLWithPath: parts[1]) : nil
        default: selection = .module(parts[0])
        }
        var size = parts[0] == "settings" ? NSSize(width: 620, height: 680) : NSSize(width: 1200, height: 780)
        let env = ProcessInfo.processInfo.environment
        if let custom = env["SHOT_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), custom.count == 2 {
            size = NSSize(width: custom[0], height: custom[1])
        }
        DebugLaunch.chatPrompt = env["SHOT_CHAT"]
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: 60, y: 60), size: size),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = env["SHOT_TITLE"] ?? "OmitX"
        switch env["SHOT_APPEARANCE"] {
        case "light": window.appearance = NSAppearance(named: .aqua)
        case "dark": window.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        // Settings is a separate scene, unreachable through ContentView — build it directly to capture it.
        // `settings:license` builds the license tab alone, because TabView always opens the first tab.
        switch parts[0] {
        case "settings" where parts.count > 1 && parts[1] == "license":
            window.contentView = NSHostingView(rootView: LicenseTab())
        case "settings" where parts.count > 1 && parts[1] == "automation":
            window.contentView = NSHostingView(rootView: AutomationView().environment(state))
        case "settings":
            window.contentView = NSHostingView(rootView: SettingsView().environment(state))
        default:
            window.contentView = NSHostingView(rootView: ContentView(initialSelection: selection).environment(state))
        }
        window.makeKeyAndOrderFront(nil)
        if selection == .dashboard { Task { await state.scanAll() } }
        Task {
            try? await Task.sleep(for: .seconds(Double(ProcessInfo.processInfo.environment["SHOT_DELAY"] ?? "") ?? 8))
            capture(window, to: out)
            exit(0)
        }
        app.run()
    }

    /// CGWindowListCreateImage is hidden from newer SDKs but still exists in CoreGraphics; capturing the app's own window needs no permission.
    static func capture(_ window: NSWindow, to path: String) {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let sym = dlsym(handle, "CGWindowListCreateImage") else { print("no symbol"); return }
        let fn = unsafeBitCast(sym, to: Fn.self)
        // kCGWindowListOptionIncludingWindow = 1 << 3, kCGWindowImageBoundsIgnoreFraming = 1 << 0
        guard let cg = fn(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue() else {
            print("capture failed"); return
        }
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif

struct OmitXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState()

    init() { MainActor.assumeIsolated { Pro.installIfAvailable() } }

    var body: some Scene {
        WindowGroup("OmitX") {
            ContentView()
                .environment(state)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Quét tất cả") { Task { await state.scanAll() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(state.isScanningAny || state.isCleaning)
            }
        }

        Settings {
            SettingsView().environment(state)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Show the Dock icon and menu even when running the bare binary (swift run).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Prints a scan report to the terminal — for quick checks; deletes nothing.
/// `OmitX --scan-report [--json] [module...]`
enum ScanReport {
    static func run(_ args: [String]) {
        let json = args.contains("--json")
        let filter = args.filter { !$0.hasPrefix("--") }
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            let settings = EngineSettings.load()
            let modules = CleanEngine.allModules(settings).filter { filter.isEmpty || filter.contains($0.id) }
            var results: [String: ScanResult] = [:]
            var grand: [CleanItem] = []
            for m in modules {
                let start = Date()
                let r = await m.scan()
                results[m.id] = r
                if !json {
                    let total = CleanItem.removeNested(r.items).reduce(0) { $0 + $1.size }
                    print("\n=== \(m.title) [\(m.id)] — \(ByteFormat.string(total)) — \(r.items.count) items — \(String(format: "%.1fs", Date().timeIntervalSince(start)))")
                    for n in r.notes { print("  ℹ︎ \(n)") }
                    for item in r.items.sorted(by: { $0.size > $1.size }) {
                        let sel = item.selectedByDefault ? "[x]" : "[ ]"
                        let size = ByteFormat.string(item.size).padding(toLength: 10, withPad: " ", startingAt: 0)
                        print("  \(sel) \(size) \(item.safety.label.padding(toLength: 9, withPad: " ", startingAt: 0)) \(item.group) › \(item.title)")
                    }
                }
                grand += r.items
            }
            var seen = Set<String>()
            let unique = CleanItem.removeNested(grand.filter { seen.insert($0.id).inserted })
            let total = unique.reduce(0) { $0 + $1.size }
            let preselected = unique.filter(\.selectedByDefault).reduce(0) { $0 + $1.size }
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .iso8601
                let report = ScanReportJSON(modules: results, total: total, preselected: preselected)
                if let data = try? encoder.encode(report), let text = String(data: data, encoding: .utf8) {
                    print(text)
                }
            } else {
                print("\nTOTAL (deduplicated): \(ByteFormat.string(total))")
                print("Preselected by default: \(ByteFormat.string(preselected))")
            }
            sem.signal()
        }
        sem.wait()
    }
}

/// Machine-readable format for `--scan-report --json`.
struct ScanReportJSON: Codable {
    var modules: [String: ScanResult]
    var total: Int64
    var preselected: Int64
}

#if DEBUG
/// Renders the dashboard / item list to a PNG — for checking the UI without screen-recording permission.
/// `OmitX --snapshot out.png [dashboard|<moduleID>]`
@MainActor
enum Snapshot {
    static func run(out: String, target: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Pro.installIfAvailable()
        let state = AppState()
        Task {
            if target == "dashboard" { await state.scanAll() } else { await state.scan(target) }
            // Render the main content with ImageRenderer (ScrollView/List cannot be captured via layers).
            let modules = state.allModules
            let firstWithItems = modules.first { !state.items($0.id).isEmpty }?.id ?? "xcode"
            let items = Array(state.items(target == "dashboard" ? firstWithItems : target).prefix(14))
            let content = VStack(alignment: .leading, spacing: 14) {
                if let v = state.volume {
                    DiskBar(total: v.total, available: v.available, reclaimable: state.grandTotal)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                    ForEach(modules, id: \.id) { m in ModuleCard(module: m) {} }
                }
                Divider()
                ForEach(items) { ItemRow(item: $0) }
            }
            .padding(20)
            .frame(width: 1000)
            .environment(state)
            .environment(\.layoutDirection, Locale.Language(identifier: AppLanguage.current).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight)
            .background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            if let img = renderer.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            }
            exit(0)
        }
        app.run()
    }
}
#endif
