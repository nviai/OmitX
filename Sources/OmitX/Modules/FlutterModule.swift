import Foundation

struct FlutterModule: CleanModule {
    let id = "flutter"
    let title = "Flutter & Dart"
    let icon = "bird.fill"
    let summary = "pub cache, Flutter SDK artifacts, FVM versions, Dart analysis server"

    func scan() async -> ScanResult {
        let pub = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PUB_CACHE"] ?? URL.homePath(".pub-cache").path)
        var specs: [PathSpec] = [
            PathSpec(pub.appendingPathComponent("hosted"), "pub cache (hosted)", group: "Pub cache",
                     note: L("flutter pub get sẽ tải lại. Giữ lại package global (bin/, global_packages/).")),
            PathSpec(pub.appendingPathComponent("git"), "pub cache (git)", group: "Pub cache"),
            PathSpec(pub.appendingPathComponent("_temp"), L("pub cache tạm"), group: "Pub cache"),
            PathSpec(home: "Library/Caches/flutter_engine", "Flutter engine cache", group: "Pub cache"),
            PathSpec(home: ".dartServer", "Dart analysis server cache", group: "Dart", note: L("IDE sẽ index lại")),
            PathSpec(home: ".dart-tool", "Dart tool data", group: "Dart"),
            PathSpec(home: "Library/Application Support/dart-code", "Dart-Code extension data", group: "Dart"),
        ]

        // Flutter SDK artifacts (bin/cache) — re-downloaded automatically by the next flutter command
        if let sdk = Self.flutterSDK() {
            specs.append(PathSpec(sdk.appendingPathComponent("bin/cache"), "Flutter SDK artifacts (bin/cache)",
                                  group: "Flutter SDK", safety: .caution,
                                  note: L("Engine, Dart SDK, artifacts iOS/Android — lệnh flutter kế tiếp sẽ tải lại (~2-4 GB)"),
                                  selected: false))
            specs.append(PathSpec(sdk.appendingPathComponent(".pub-cache"), "SDK .pub-cache", group: "Flutter SDK"))
        }

        // FVM
        for dir in [URL.homePath("fvm/versions"), URL.homePath("Library/Application Support/fvm/versions")] {
            specs += ScanKit.children(of: dir, group: "FVM versions", safety: .caution,
                                      note: L("Project đang pin bản này sẽ phải fvm install lại"), selected: false,
                                      title: { "Flutter \($0.lastPathComponent)" })
        }
        specs.append(PathSpec(home: "fvm/cache.git", "FVM git cache", group: "FVM versions", safety: .caution, selected: false))

        return ScanResult(items: await ScanKit.measure(specs),
                          notes: [L("Thư mục build/ và .dart_tool/ trong từng project nằm ở mục \"Project\".")])
    }

    static func flutterSDK() -> URL? {
        guard let bin = Shell.which("flutter") else { return nil }
        // …/flutter/bin/flutter → …/flutter (resolving fvm/brew symlinks)
        let resolved = URL(fileURLWithPath: bin).resolvingSymlinksInPath()
        let root = resolved.deletingLastPathComponent().deletingLastPathComponent()
        return root.appendingPathComponent("bin/cache").exists ? root : nil
    }
}
