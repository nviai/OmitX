import Foundation

struct AndroidModule: CleanModule {
    let id = "android"
    let title = "Android & Gradle"
    let icon = "apps.iphone"
    let summary = L("Gradle caches & wrapper cũ, Android SDK (system images, build-tools, NDK), AVD, Android Studio")

    static let stopGradle = ShellCommand(executable: "pkill", arguments: ["-f", "GradleDaemon"])

    func scan() async -> ScanResult {
        var specs: [PathSpec] = []
        var extra: [CleanItem] = []

        // ---- Gradle ----
        let gradle = URL.homePath(".gradle")
        let g = "Gradle"
        specs += [
            PathSpec(gradle.appendingPathComponent("caches"), "Gradle caches", group: g,
                     note: L("Dừng Gradle daemon rồi xoá. Lần build sau sẽ tải lại dependency."),
                     preCommand: Self.stopGradle),
            PathSpec(gradle.appendingPathComponent("daemon"), "Gradle daemon logs", group: g, preCommand: Self.stopGradle),
            PathSpec(gradle.appendingPathComponent("native"), "Gradle native", group: g),
            PathSpec(gradle.appendingPathComponent(".tmp"), "Gradle tmp", group: g),
            PathSpec(gradle.appendingPathComponent("build-scan-data"), "Build scan data", group: g),
            PathSpec(gradle.appendingPathComponent("kotlin-profile"), "Kotlin profile", group: g),
            PathSpec(gradle.appendingPathComponent("jdks"), L("JDK do Gradle tự tải"), group: g, safety: .caution),
        ]

        // Wrapper dists — keep the newest
        let dists = gradle.appendingPathComponent("wrapper/dists").children(includeHidden: false)
            .filter { $0.lastPathComponent.hasPrefix("gradle-") }
            .sorted { ScanKit.versionLess(Self.gradleVersion($0), Self.gradleVersion($1)) }
        let newestVersion = dists.last.map(Self.gradleVersion)
        for d in dists {
            let newest = Self.gradleVersion(d) == newestVersion
            specs.append(PathSpec(d, d.lastPathComponent, group: "Gradle Wrapper",
                                  note: newest ? L("Bản mới nhất — giữ lại") : L("Project cần bản này sẽ tự tải lại"),
                                  selected: !newest))
        }

        // ---- Android SDK ----
        let sdk = Self.sdkRoot()
        if let sdk {
            specs += Self.versioned(sdk.appendingPathComponent("build-tools"), group: "SDK Build Tools",
                                    note: L("Project cần phiên bản nào sẽ tải lại"))
            specs += Self.versioned(sdk.appendingPathComponent("ndk"), group: "SDK NDK",
                                    note: L("Kiểm tra ndkVersion trong build.gradle trước khi xoá"))
            specs += Self.versioned(sdk.appendingPathComponent("cmake"), group: "SDK CMake")
            specs += ScanKit.children(of: sdk.appendingPathComponent("platforms"), group: "SDK Platforms",
                                      safety: .caution, note: L("compileSdk cần bản này"))
            specs += ScanKit.children(of: sdk.appendingPathComponent("sources"), group: "SDK Sources",
                                      note: L("Mã nguồn Android để xem trong IDE"))
            // system-images/<api>/<tag>/<abi>
            for api in sdk.appendingPathComponent("system-images").children(includeHidden: false) {
                for tag in api.children(includeHidden: false) {
                    for abi in tag.children(includeHidden: false) {
                        specs.append(PathSpec(abi, "\(api.lastPathComponent) · \(tag.lastPathComponent) · \(abi.lastPathComponent)",
                                              group: "SDK System Images", safety: .caution,
                                              note: L("AVD dùng image này sẽ không chạy được"), selected: false))
                    }
                }
            }
            specs.append(PathSpec(sdk.appendingPathComponent(".temp"), "SDK temp", group: "SDK Cache"))
            specs.append(PathSpec(sdk.appendingPathComponent(".downloadIntermediates"), L("SDK download tạm"), group: "SDK Cache"))
        }

        // ---- AVD (emulator) ----
        let avdRoot = URL.homePath(".android/avd")
        let avds = avdRoot.children(includeHidden: false).filter { $0.pathExtension == "avd" }
        extra += await concurrentMap(avds) { avd in
            let name = avd.deletingPathExtension().lastPathComponent
            let ini = avdRoot.appendingPathComponent("\(name).ini")
            let paths = [avd, ini].filter(\.exists)
            return CleanItem(id: "avd:\(avd.path)", title: name.replacingOccurrences(of: "_", with: " "),
                             detail: avd.path.abbreviatingHome, group: "Android Emulator (AVD)",
                             size: DiskUsage.size(ofPaths: paths.map(\.path)), safety: .danger,
                             note: L("Xoá máy ảo + toàn bộ dữ liệu trong đó"), action: .deletePaths(paths),
                             selectedByDefault: false, lastModified: avd.modificationDate,
                             blockingProcesses: ["qemu-system"])
        }
        let avdSnapshots = avds.map { $0.appendingPathComponent("snapshots") }
        specs += avdSnapshots.map {
            PathSpec($0, "Snapshot \($0.deletingLastPathComponent().deletingPathExtension().lastPathComponent)",
                     group: "Android Emulator (AVD)", note: L("Mất quick-boot snapshot, lần sau cold boot"), blocking: ["qemu-system"])
        }

        // ---- ~/.android & Android Studio ----
        let a = "Android Studio"
        specs += [
            PathSpec(home: ".android/cache", "~/.android/cache", group: a),
            PathSpec(home: ".android/build-cache", "Android build cache", group: a),
            PathSpec(home: ".konan", "Kotlin/Native (.konan)", group: a, safety: .caution, note: L("Tải lại khi build KMP")),
            PathSpec(home: "Library/Application Support/kotlin/daemon", "Kotlin daemon logs", group: a),
        ]
        specs += Self.studioDirs(URL.homePath("Library/Caches/Google"), kind: "Cache")
        specs += Self.studioDirs(URL.homePath("Library/Logs/Google"), kind: "Logs")
        // Config of old Android Studio versions (keep the newest)
        let configs = URL.homePath("Library/Application Support/Google").children(includeHidden: false)
            .filter { $0.lastPathComponent.hasPrefix("AndroidStudio") }
            .sorted { ScanKit.versionLess($0.lastPathComponent, $1.lastPathComponent) }
        for c in configs.dropLast() {
            specs.append(PathSpec(c, L("Cấu hình \(c.lastPathComponent) (bản cũ)"), group: a, safety: .caution,
                                  note: L("Settings/plugin của phiên bản Android Studio cũ đã được migrate"), selected: true))
        }

        var notes: [String] = []
        if sdk == nil { notes.append(L("Không tìm thấy Android SDK.")) }
        if Shell.isRunning("GradleDaemon") { notes.append(L("Gradle daemon đang chạy — app sẽ tự dừng (pkill) trước khi xoá Gradle caches.")) }
        return ScanResult(items: await ScanKit.measure(specs) + extra, notes: notes)
    }

    static func sdkRoot() -> URL? {
        let env = ProcessInfo.processInfo.environment
        let candidates = [env["ANDROID_HOME"], env["ANDROID_SDK_ROOT"]].compactMap { $0 }.map { URL(fileURLWithPath: $0) }
            + [URL.homePath("Library/Android/sdk"), URL(fileURLWithPath: "/opt/homebrew/share/android-commandlinetools")]
        return candidates.first { $0.isDirectory }
    }

    /// One item per version; old versions are preselected, the newest is kept.
    static func versioned(_ dir: URL, group: String, note: String? = nil) -> [PathSpec] {
        let list = dir.children(includeHidden: false).sorted { ScanKit.versionLess($0.lastPathComponent, $1.lastPathComponent) }
        return list.map { v in
            let newest = v == list.last
            return PathSpec(v, v.lastPathComponent, group: group, safety: .caution,
                            note: newest ? L("Bản mới nhất") : note, selected: false)
        }
    }

    static func studioDirs(_ dir: URL, kind: String) -> [PathSpec] {
        dir.children(includeHidden: false).filter { $0.lastPathComponent.hasPrefix("AndroidStudio") }.map {
            PathSpec($0, "\($0.lastPathComponent) \(kind)", group: "Android Studio", blocking: ["Android Studio"])
        }
    }

    /// "gradle-8.14.3-all" → "8.14.3"
    static func gradleVersion(_ url: URL) -> String {
        var n = url.lastPathComponent
        n = n.replacingOccurrences(of: "gradle-", with: "")
        for suffix in ["-all", "-bin"] where n.hasSuffix(suffix) { n.removeLast(suffix.count) }
        return n
    }
}
