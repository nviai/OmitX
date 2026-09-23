import XCTest
import Darwin
@testable import OmitX

final class AgentTempTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("omitx-agent-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // Real path (/private/var/…), like TempModule.userTempDir and lsof report it.
        let real = realpath(tmp.path, nil)!
        tmp = URL(fileURLWithPath: String(cString: real))
        free(real)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Creates `rel` with `bytes` of data and backdates it (and its parent folders inside tmp) by `age` seconds.
    @discardableResult
    private func write(_ rel: String, bytes: Int = 2_000_000, age: TimeInterval) throws -> URL {
        let url = tmp.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        let date = Date().addingTimeInterval(-age)
        var dir = url
        while dir.path.count > tmp.path.count {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: dir.path)
            dir = dir.deletingLastPathComponent()
        }
        return url
    }

    private func scan(open: Set<String> = []) async -> [CleanItem] {
        let root = TempModule.Root(url: tmp, label: "/tmp", containers: ["claude-\(getuid())"])
        return await TempModule.scan(root, uid: getuid(), open: open)
    }

    // MARK: AI agents

    func testClaudeProjectNameDropsHomePrefix() {
        let home = NSHomeDirectory().replacingOccurrences(of: "/", with: "-")
        XCTAssertEqual(AIAgentModule.projectName(home + "-Workspaces-App"), "Workspaces-App")
        XCTAssertEqual(AIAgentModule.projectName(home), "~")
        XCTAssertEqual(AIAgentModule.projectName("-private-tmp-x"), "-private-tmp-x")
    }

    // MARK: Temp files

    func testTempSkipsSystemAndLockNames() {
        for name in ["com.apple.launchd.abc", "tmux-501", "ssh-XXXX", "app.sock", "server.pid", "db.lock", ".X11-unix"] {
            XCTAssertFalse(TempModule.eligibleName(name), name)
        }
        for name in ["flutter_tools.abc", "pytest-of-me", "claude-501", "_bak.html"] {
            XCTAssertTrue(TempModule.eligibleName(name), name)
        }
    }

    func testTreeInfoFlagsFifo() throws {
        let dir = tmp.appendingPathComponent("with-fifo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(dir.appendingPathComponent("pipe").path, 0o600), 0)
        XCTAssertEqual(TreeInfo.walk(dir)?.hasSpecial, true)
    }

    func testTempRatesByAgeAndSkipsActiveOrOpen() async throws {
        try write("old/a.bin", age: 5 * 86_400)
        try write("recent/a.bin", age: 86_400)
        try write("active/a.bin", age: 60)
        let open = try write("held/a.bin", age: 5 * 86_400)
        // Loose small files are bundled only when stale.
        try write("small1.txt", bytes: 200_000, age: 5 * 86_400)
        try write("small2.txt", bytes: 200_000, age: 5 * 86_400)

        let items = await scan(open: [open.path])
        let byTitle = Dictionary(uniqueKeysWithValues: items.map { ($0.title, $0) })

        XCTAssertEqual(byTitle["old"]?.safety, .safe)
        XCTAssertEqual(byTitle["old"]?.selectedByDefault, true)
        XCTAssertEqual(byTitle["recent"]?.safety, .caution)
        XCTAssertEqual(byTitle["recent"]?.selectedByDefault, false)
        XCTAssertNil(byTitle["active"], "written in the last hour")
        XCTAssertNil(byTitle["held"], "open in a process")

        let loose = items.first { $0.id.hasPrefix("temp-loose:") }
        XCTAssertEqual(loose?.paths.count, 2)
    }

    func testTempWithoutLsofNeverPreselects() async throws {
        try write("old/a.bin", age: 5 * 86_400)
        let root = TempModule.Root(url: tmp, label: "/tmp", containers: [])
        let items = await TempModule.scan(root, uid: getuid(), open: nil)
        XCTAssertEqual(items.first { $0.title == "old" }?.safety, .caution)
        XCTAssertFalse(items.contains { $0.selectedByDefault })
    }

    func testTempSplitsAgentContainerPerProject() async throws {
        let container = "claude-\(getuid())"
        try write("\(container)/-Users-me-App/tasks/out.txt", age: 5 * 86_400)
        try write("\(container)/-Users-me-Live/tasks/out.txt", age: 60)

        let items = await scan()
        XCTAssertEqual(items.map(\.title), ["-Users-me-App"])
        XCTAssertEqual(items.first?.group, "/tmp/\(container)")
    }
}
