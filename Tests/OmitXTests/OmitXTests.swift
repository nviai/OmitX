import XCTest
@testable import OmitX

final class OmitXTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("omitx-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        _ = try? Shell.runRaw("/bin/chmod", ["-R", "u+w", tmp.path], env: [:], timeout: 10)
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ rel: String, bytes: Int = 10_000) throws -> URL {
        let url = tmp.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }

    // MARK: Path guard

    func testProtectedPathsAreRejected() {
        let h = NSHomeDirectory()
        for p in ["/", h, "\(h)/Library", "\(h)/Library/Caches", "\(h)/Documents", "/System", "/System/Library/Foo",
                  "/usr/bin", "/Applications", "\(h)/.ssh/id_rsa", "\(h)/Library/Keychains/login.keychain-db"] {
            XCTAssertThrowsError(try Cleaner.validate(URL(fileURLWithPath: p)), p)
        }
        XCTAssertNoThrow(try Cleaner.validate(URL(fileURLWithPath: "\(h)/Library/Caches/pip")))
        XCTAssertNoThrow(try Cleaner.validate(URL(fileURLWithPath: "\(h)/Library/Developer/Xcode/DerivedData")))
    }

    func testContainerGuard() {
        let h = NSHomeDirectory()
        for p in ["/", h, "\(h)/Library", "\(h)/Documents", "\(h)/Library/Application Support"] {
            XCTAssertThrowsError(try Cleaner.validateContainer(URL(fileURLWithPath: p)), p)
        }
        XCTAssertNoThrow(try Cleaner.validateContainer(URL(fileURLWithPath: "\(h)/Library/Caches")))
        XCTAssertNoThrow(try Cleaner.validateContainer(URL(fileURLWithPath: "\(h)/Library/Logs")))
    }

    // MARK: Deletion

    func testDeleteRemovesReadOnlyTree() async throws {
        // Like the Go module cache: read-only folders & files
        let file = try write("mod/github.com/x/y@v1/a.go")
        let dir = tmp.appendingPathComponent("mod")
        _ = try Shell.runRaw("/bin/chmod", ["-R", "a-w", dir.path], env: [:], timeout: 10)
        XCTAssertTrue(file.exists)

        let item = CleanItem(id: "t", title: "t", group: "g", size: DiskUsage.size(of: dir), safety: .safe,
                             action: .delete(dir), selectedByDefault: true)
        let outcome = await Cleaner.clean(item, mode: .permanent)
        XCTAssertNil(outcome.error)
        XCTAssertFalse(dir.exists)
        XCTAssertGreaterThan(outcome.freed, 0)
    }

    func testDeleteContentsKeepsContainer() async throws {
        _ = try write("cache/a.bin")
        _ = try write("cache/sub/b.bin")
        _ = try write("cache/.hidden")
        let cache = tmp.appendingPathComponent("cache")
        let item = CleanItem(id: "t", title: "t", group: "g", size: DiskUsage.size(of: cache), safety: .safe,
                             action: .deleteContents(cache), selectedByDefault: true)
        let outcome = await Cleaner.clean(item, mode: .permanent)
        XCTAssertNil(outcome.error)
        XCTAssertTrue(cache.isDirectory)
        XCTAssertEqual(cache.children().count, 0)
    }

    func testDeletePathsRemovesAll() async throws {
        let a = try write("avd/Pixel.avd/disk.img")
        let ini = try write("avd/Pixel.ini", bytes: 10)
        let avd = a.deletingLastPathComponent()
        let item = CleanItem(id: "t", title: "t", group: "g", size: 1, safety: .danger,
                             action: .deletePaths([avd, ini]), selectedByDefault: false)
        let outcome = await Cleaner.clean(item, mode: .permanent)
        XCTAssertNil(outcome.error)
        XCTAssertFalse(avd.exists)
        XCTAssertFalse(ini.exists)
    }

    func testDeleteDoesNotFollowSymlinks() async throws {
        let target = try write("real/keep.txt")
        let link = tmp.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target.deletingLastPathComponent())
        let item = CleanItem(id: "t", title: "t", group: "g", size: 1, safety: .safe,
                             action: .delete(link), selectedByDefault: true)
        _ = await Cleaner.clean(item, mode: .permanent)
        XCTAssertFalse(DiskUsage.isSymlink(link.path))
        XCTAssertTrue(target.exists, "Must not delete the file a symlink points to")
    }

    // MARK: Size

    func testDiskUsageCountsHardLinksOnce() throws {
        let a = try write("h/a.bin", bytes: 1_000_000)
        let b = tmp.appendingPathComponent("h/b.bin")
        try FileManager.default.linkItem(at: a, to: b)
        let single = DiskUsage.size(of: a)
        let dir = DiskUsage.size(of: tmp.appendingPathComponent("h"))
        XCTAssertLessThan(dir, single * 2)
    }

    // MARK: Dedupe

    func testRemoveNested() {
        func item(_ id: String, _ action: CleanAction) -> CleanItem {
            CleanItem(id: id, title: id, group: "g", size: 10, safety: .safe, action: action, selectedByDefault: true)
        }
        let items = [
            item("caches", .delete(URL(fileURLWithPath: "/x/Library/Caches/pypoetry"))),
            item("inner", .delete(URL(fileURLWithPath: "/x/Library/Caches/pypoetry/cache"))),
            item("logs", .deleteContents(URL(fileURLWithPath: "/x/Library/Logs"))),
            item("brewlogs", .delete(URL(fileURLWithPath: "/x/Library/Logs/Homebrew"))),
            item("sibling", .delete(URL(fileURLWithPath: "/x/Library/Caches/pypoetry-other"))),
            item("cmd", .command(ShellCommand(executable: "docker", arguments: ["builder", "prune"]))),
        ]
        let kept = Set(AppState.removeNested(items).map(\.id))
        XCTAssertEqual(kept, ["caches", "logs", "sibling", "cmd"])
    }

    // MARK: Parsers

    func testByteFormatParse() {
        XCTAssertEqual(ByteFormat.parse("2.5GB"), 2_500_000_000)
        XCTAssertEqual(ByteFormat.parse("746.3MB (26%)"), 746_300_000)
        XCTAssertEqual(ByteFormat.parse("0B"), 0)
        XCTAssertEqual(ByteFormat.parse("12kB"), 12_000)
        XCTAssertEqual(HomebrewModule.parseFreeSize("==> This operation would free approximately 1.2GB of disk space."),
                       1_200_000_000)
    }

    func testVersionHelpers() {
        XCTAssertTrue(ScanKit.versionLess("8.9", "8.14.3"))
        XCTAssertEqual(AndroidModule.gradleVersion(URL(fileURLWithPath: "/g/gradle-8.14.3-all")), "8.14.3")
        XCTAssertEqual(SimulatorModule.platformName("com.apple.CoreSimulator.SimRuntime.iOS-18-3"), "iOS 18.3")
    }

    // MARK: Project scanner

    func testProjectWalkFindsArtifacts() throws {
        _ = try write("ws/flutter_app/pubspec.yaml", bytes: 10)
        _ = try write("ws/flutter_app/build/out.bin")
        _ = try write("ws/flutter_app/.dart_tool/x")
        _ = try write("ws/flutter_app/ios/Podfile", bytes: 10)
        _ = try write("ws/flutter_app/ios/Pods/lib.a")
        _ = try write("ws/web/package.json", bytes: 10)
        _ = try write("ws/web/node_modules/react/index.js")
        _ = try write("ws/web/node_modules/nested/node_modules/x.js")
        _ = try write("ws/py/.venv/pyvenv.cfg", bytes: 10)
        _ = try write("ws/notproj/build/keep.txt")         // no marker → must not be touched
        _ = try write("ws/fakevenv/.venv/random.txt")       // no pyvenv.cfg → skipped

        var found: [ProjectModule.Found] = []
        ProjectModule.walk(tmp.appendingPathComponent("ws"), depth: 0, maxDepth: 6, projectRoot: nil, into: &found)
        let rel = Set(found.map { $0.url.path.components(separatedBy: "/ws/").last ?? "" })
        XCTAssertEqual(rel, ["flutter_app/build", "flutter_app/.dart_tool", "flutter_app/ios/Pods",
                             "web/node_modules", "py/.venv"])
    }

    // MARK: Uninstaller matching

    func testUninstallerNormalize() {
        XCTAssertEqual(AppUninstaller.normalize("Visual Studio Code"), "visualstudiocode")
        XCTAssertEqual(AppUninstaller.normalize("zalo-updater"), "zaloupdater")
    }

    // MARK: Localization

    func testLanguageListHasNoDuplicates() {
        XCTAssertEqual(AppLanguage.languages(from: ["en", "vi", "Base", "ja", "en", "vi", "ja"]), ["en", "vi", "ja"])
        XCTAssertEqual(AppLanguage.languages(from: []), ["vi"])
    }

    func testCatalogHasEveryLanguage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Localization/Localizable.xcstrings"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: [String: Any]])
        XCTAssertGreaterThan(strings.count, 200)
        let langs = ["vi", "en", "ar", "ca", "cs", "da", "de", "el", "es", "fi", "fr", "he", "hi", "hr", "hu", "id", "it", "ja",
                     "ko", "ms", "nb", "nl", "pl", "pt-BR", "pt-PT", "ro", "ru", "sk", "sl", "sv", "th", "tr", "uk",
                     "zh-Hans", "zh-Hant"]
        var missing: [String] = []
        for (key, entry) in strings {
            let locs = entry["localizations"] as? [String: Any] ?? [:]
            for lang in langs where locs[lang] == nil { missing.append("\(lang): \(key)") }
        }
        XCTAssertTrue(missing.isEmpty, "Missing translations:\n" + missing.prefix(20).joined(separator: "\n"))
    }

    // MARK: CleanQuery

    private func qItem(_ id: String, size: Int64 = 1_000_000, safety: Safety = .safe,
                       group: String = "g", action: CleanAction? = nil,
                       lastModified: Date? = nil, blocking: [String] = []) -> CleanItem {
        CleanItem(id: id, title: id, group: group, size: size, safety: safety,
                  action: action ?? .delete(URL(fileURLWithPath: "/x/\(id)")),
                  selectedByDefault: true, lastModified: lastModified, blockingProcesses: blocking)
    }

    func testCleanQueryFiltersBySafety() {
        let items = [qItem("a", safety: .safe), qItem("b", safety: .caution), qItem("c", safety: .danger)]
        let results = ["xcode": ScanResult(items: items)]

        let safeOnly = CleanEngine.resolve(CleanQuery(), in: results)
        XCTAssertEqual(safeOnly.map(\.id), ["a"])

        let upToCaution = CleanEngine.resolve(CleanQuery(maxSafety: .caution), in: results)
        XCTAssertEqual(Set(upToCaution.map(\.id)), ["a", "b"])
    }

    func testCleanQueryExcludesAdminItems() {
        let admin = ShellCommand(executable: "rm", arguments: ["-rf", "/Library/Caches"], admin: true)
        let plain = ShellCommand(executable: "docker", arguments: ["system", "prune"])
        let items = [
            qItem("admin", action: .command(admin)),
            qItem("adminThenDelete", action: .commandThenDelete(admin, URL(fileURLWithPath: "/x/y"))),
            qItem("plain", action: .command(plain)),
        ]
        let results = ["system": ScanResult(items: items)]

        XCTAssertEqual(CleanEngine.resolve(CleanQuery(), in: results).map(\.id), ["plain"])
        // Admin items appear only with the guard off — used by flows where a person confirms.
        let all = CleanEngine.resolve(CleanQuery(excludeAdmin: false), in: results)
        XCTAssertEqual(Set(all.map(\.id)), ["admin", "adminThenDelete", "plain"])
    }

    func testCleanQuerySkipsItemsWithRunningBlocker() {
        let items = [qItem("derived", blocking: ["Xcode"]), qItem("cache", blocking: ["Android Studio"])]
        let results = ["xcode": ScanResult(items: items)]

        let running: Set<String> = ["Xcode"]
        XCTAssertEqual(CleanEngine.resolve(CleanQuery(), in: results, running: running).map(\.id), ["cache"])
        XCTAssertEqual(Set(CleanEngine.resolve(CleanQuery(), in: results).map(\.id)), ["derived", "cache"])
        // skipBlocked = false bypasses the guard (supervised flows)
        let ignored = CleanEngine.resolve(CleanQuery(skipBlocked: false), in: results, running: running)
        XCTAssertEqual(Set(ignored.map(\.id)), ["derived", "cache"])
    }

    func testCleanQueryStaleDays() {
        let old = Date().addingTimeInterval(-100 * 86_400)
        let items = [qItem("old", lastModified: old), qItem("fresh", lastModified: Date()), qItem("unknown")]
        let results = ["projects": ScanResult(items: items)]

        // Items without a timestamp must be excluded — never guess when deleting automatically.
        XCTAssertEqual(CleanEngine.resolve(CleanQuery(staleDays: 90), in: results).map(\.id), ["old"])
        XCTAssertEqual(Set(CleanEngine.resolve(CleanQuery(), in: results).map(\.id)), ["old", "fresh", "unknown"])
    }

    func testCleanQueryMinSizeGroupsAndLimit() {
        let items = [qItem("big", size: 9_000_000, group: "Xcode"), qItem("mid", size: 5_000_000, group: "Xcode"),
                     qItem("small", size: 1_000, group: "Xcode"), qItem("other", size: 8_000_000, group: "Docker")]
        let results = ["xcode": ScanResult(items: items)]

        XCTAssertEqual(CleanEngine.resolve(CleanQuery(minSize: 2_000_000), in: results).map(\.id),
                       ["big", "other", "mid"])  // sorted by size, descending
        XCTAssertEqual(CleanEngine.resolve(CleanQuery(groups: ["xcode"]), in: results).map(\.id),
                       ["big", "mid", "small"])  // case-insensitive match
        XCTAssertEqual(CleanEngine.resolve(CleanQuery(limit: 2), in: results).map(\.id), ["big", "other"])
    }

    func testResolveFiltersModulesAndRemovesNested() {
        let xcode = ScanResult(items: [
            qItem("parent", action: .delete(URL(fileURLWithPath: "/x/DerivedData"))),
            qItem("child", action: .delete(URL(fileURLWithPath: "/x/DerivedData/App-abc"))),
        ])
        let docker = ScanResult(items: [qItem("docker", action: .delete(URL(fileURLWithPath: "/x/docker")))])
        let results = ["xcode": xcode, "docker": docker]

        XCTAssertEqual(Set(CleanEngine.resolve(CleanQuery(), in: results).map(\.id)), ["parent", "docker"])
        XCTAssertEqual(CleanEngine.resolve(CleanQuery(modules: ["xcode"]), in: results).map(\.id), ["parent"])
    }

    // MARK: Codable

    func testCleanActionCodableRoundTrip() throws {
        let url = URL(fileURLWithPath: "/x/y")
        let cmd = ShellCommand(executable: "docker", arguments: ["system", "prune", "-af"], admin: true)
        let actions: [CleanAction] = [
            .delete(url), .deleteContents(url), .command(cmd),
            .commandThenDelete(cmd, url), .deletePaths([url, URL(fileURLWithPath: "/x/z")]), .recycle(url),
        ]
        for action in actions {
            let data = try JSONEncoder().encode(action)
            XCTAssertEqual(try JSONDecoder().decode(CleanAction.self, from: data), action, "\(action)")
        }
    }

    func testCleanItemAndQueryCodableRoundTrip() throws {
        let item = CleanItem(
            id: "path:/x/y", title: "DerivedData", detail: "~/x/y", group: "Xcode", size: 42,
            safety: .caution, note: "ghi chú", action: .delete(URL(fileURLWithPath: "/x/y")),
            selectedByDefault: true, lastModified: Date(timeIntervalSinceReferenceDate: 700_000_000),
            blockingProcesses: ["Xcode"])
        let itemData = try JSONEncoder().encode(item)
        XCTAssertEqual(try JSONDecoder().decode(CleanItem.self, from: itemData), item)

        let query = CleanQuery(modules: ["xcode"], groups: ["Xcode"], maxSafety: .caution,
                               minSize: 1024, staleDays: 30, excludeAdmin: false, skipBlocked: false, limit: 5)
        let queryData = try JSONEncoder().encode(query)
        XCTAssertEqual(try JSONDecoder().decode(CleanQuery.self, from: queryData), query)
    }

    func testEngineSettingsRoundTripsThroughUserDefaults() throws {
        let suite = "omitx-tests-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let settings = EngineSettings(deleteMode: .trash, projectRoots: [tmp],
                                      projectMaxDepth: 4, staleDays: 180)
        settings.save(to: d)
        let loaded = EngineSettings.load(from: d)
        XCTAssertEqual(loaded.projectRoots.map(\.path), settings.projectRoots.map(\.path))
        XCTAssertEqual(loaded.deleteMode, settings.deleteMode)
        XCTAssertEqual(loaded.projectMaxDepth, settings.projectMaxDepth)
        XCTAssertEqual(loaded.staleDays, settings.staleDays)

        // Keys keep their old names so existing users do not lose their settings.
        XCTAssertEqual(d.string(forKey: "deleteMode"), "trash")
        XCTAssertEqual(d.object(forKey: "staleDays") as? Int, 180)
    }

    func testUnattendedQueryIsLockedDown() {
        let q = CleanQuery.unattended
        XCTAssertEqual(q.maxSafety, .safe)
        XCTAssertTrue(q.excludeAdmin)
        XCTAssertTrue(q.skipBlocked)
    }


    // MARK: Automation rule guardrails

    private func rule(_ action: CleanRule.Action, safety: Safety = .safe) -> CleanRule {
        CleanRule(name: "test", trigger: .freeSpaceBelow(20_000_000_000),
                  query: CleanQuery(maxSafety: safety, excludeAdmin: false, skipBlocked: false),
                  action: action)
    }

    func testRuleRejectsUnsafeQueryWhenItDeletes() {
        for action in [CleanRule.Action.askApproval, .deleteNow] {
            for safety in [Safety.caution, .danger] {
                XCTAssertThrowsError(try rule(action, safety: safety).validated(), "\(action) \(safety)")
            }
        }
        // Notify-only deletes nothing, so it may look at Caution items too.
        XCTAssertNoThrow(try rule(.notifyOnly, safety: .caution).validated())
    }

    func testRuleValidationForcesUnattendedRails() throws {
        // Even if the user turns these two guards off in the query, validated() turns them back on.
        let validated = try rule(.deleteNow).validated()
        XCTAssertTrue(validated.query.excludeAdmin)
        XCTAssertTrue(validated.query.skipBlocked)

        XCTAssertThrowsError(try CleanRule(name: "  ").validated())
    }

    func testRuleCapsBytesPerRun() {
        var r = rule(.deleteNow)
        r.maxBytesPerRun = 10_000_000
        let items = [qItem("a", size: 6_000_000), qItem("b", size: 3_000_000), qItem("c", size: 5_000_000)]
        // Stop as soon as the next item would exceed the cap; no skipping ahead.
        XCTAssertEqual(r.capped(items).map(\.id), ["a", "b"])

        r.maxBytesPerRun = nil
        XCTAssertEqual(r.capped(items).count, 3)
    }





    // MARK: Warning threshold & history

    func testWarnThresholdDebouncesForSixHours() {
        let now = Date()
        var a = AutomationSettings(enabled: true, warnBelowBytes: 40_000_000_000)
        XCTAssertTrue(a.shouldWarn(freeBytes: 30_000_000_000, now: now))
        XCTAssertFalse(a.shouldWarn(freeBytes: 50_000_000_000, now: now), "plenty of space → stay quiet")

        a.lastWarnedAt = now.addingTimeInterval(-3600)
        XCTAssertFalse(a.shouldWarn(freeBytes: 30_000_000_000, now: now), "already warned an hour ago")
        a.lastWarnedAt = now.addingTimeInterval(-7 * 3600)
        XCTAssertTrue(a.shouldWarn(freeBytes: 30_000_000_000, now: now))

        a.enabled = false
        a.lastWarnedAt = nil
        XCTAssertFalse(a.shouldWarn(freeBytes: 30_000_000_000, now: now))
    }

    func testAutomationAndHistoryRoundTripOnDisk() throws {
        let file = tmp.appendingPathComponent("automation.json")
        var a = AutomationSettings(enabled: true, warnBelowBytes: 1234, actBelowBytes: 567)
        a.rules = [try rule(.deleteNow).validated()]
        try a.save(to: file)
        XCTAssertEqual(AutomationSettings.load(from: file), a)

        // A corrupt or missing file returns the defaults instead of crashing.
        XCTAssertEqual(AutomationSettings.load(from: tmp.appendingPathComponent("nope.json")), AutomationSettings())

        let historyFile = tmp.appendingPathComponent("history.json")
        var h = RunHistory()
        for i in 0..<(RunHistory.limit + 10) {
            h.append(RuleRun(ruleID: UUID(), ruleName: "r\(i)", date: Date(), matched: 1, bytes: 1,
                             action: .deleteNow, executed: true, freed: 1, errors: []))
        }
        XCTAssertEqual(h.runs.count, RunHistory.limit)
        XCTAssertEqual(h.runs.first?.ruleName, "r\(RunHistory.limit + 9)", "newest first")
        try h.save(to: historyFile)
        XCTAssertEqual(RunHistory.load(from: historyFile).runs.count, RunHistory.limit)
    }


    // MARK: Chat bridge



    @MainActor
    func testChatModeDefaultsToPropose() {
        let model = ChatModel(state: AppState(), onPropose: { _ in })
        XCTAssertEqual(model.mode, .propose)
        XCTAssertFalse(model.suggestions.isEmpty)
    }

    // MARK: Pro gate

    func testLicenseStateUnlockRules() {
        for state in [LicenseState.active, .trial(daysLeft: 3), .grace(daysLeft: 1)] {
            XCTAssertTrue(state.unlocksPro, "\(state)")
        }
        for state in [LicenseState.none, .expired, .revoked] {
            XCTAssertFalse(state.unlocksPro, "\(state)")
        }
    }

    /// Correct in both build modes: with Pro/ it loads, without it everything stays locked.
    @MainActor
    func testProInstallHookMatchesBuildMode() {
        let bridgeExists = NSClassFromString("OmitXProBootstrap") != nil
        Pro.installIfAvailable()
        XCTAssertEqual(Pro.isLinked, bridgeExists,
                       bridgeExists ? "Pro/ present but failed to load" : "no Pro/ yet something loaded")
    }

    @MainActor
    func testProRegistryLocksDownWhenPackageMissing() {
        // Simulates the community build: without the Pro package everything must stay locked.
        let chat = Pro.chat, automation = Pro.automation, license = Pro.license, agent = Pro.runAgent
        defer { Pro.chat = chat; Pro.automation = automation; Pro.license = license; Pro.runAgent = agent }

        Pro.chat = nil; Pro.automation = nil; Pro.license = nil; Pro.runAgent = nil
        XCTAssertFalse(Pro.isLinked)
        XCTAssertFalse(Pro.isUnlocked)
        XCTAssertEqual(Pro.state, .none)

        // The ChatModel shell must work without an engine.
        let model = ChatModel(state: AppState(), onPropose: { _ in })
        XCTAssertEqual(model.availability, .unsupportedOS)
        model.clear()
    }

}
