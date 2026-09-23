import Foundation

struct SystemModule: CleanModule {
    let id = "system"
    let title = L("Hệ thống")
    let icon = "gearshape.2.fill"
    let summary = L("~/Library/Caches, Logs, Saved Application State, Thùng rác, /Library/Caches (admin), backup iPhone")

    func scan() async -> ScanResult {
        var specs: [PathSpec] = []

        // Each folder in ~/Library/Caches
        let caches = URL.homePath("Library/Caches")
        for child in caches.children() {
            let name = child.lastPathComponent
            let isApple = name.hasPrefix("com.apple.")
            specs.append(PathSpec(child, name, group: "~/Library/Caches",
                                  safety: isApple ? .caution : .safe,
                                  note: isApple ? L("Cache hệ thống của Apple — tự tạo lại, nhưng có thể đang được dùng") : nil,
                                  selected: !isApple))
        }

        let g = L("Logs & trạng thái")
        specs += [
            PathSpec(home: "Library/Logs", L("User logs"), group: g, contentsOnly: true),
            PathSpec(home: "Library/Saved Application State", "Saved Application State", group: g,
                     note: L("Mất trạng thái cửa sổ khi mở lại app"), contentsOnly: true),
            PathSpec(home: "Library/Application Support/CrashReporter", L("Crash reports"), group: g, contentsOnly: true),
            PathSpec(home: "Library/HTTPStorages", L("HTTP storages (cookie/cache của app)"), group: g, safety: .caution,
                     note: L("Một số app sẽ phải đăng nhập lại"), contentsOnly: true, selected: false),
            PathSpec(home: ".Trash", L("Thùng rác"), group: g, safety: .caution,
                     note: L("Dọn sạch Thùng rác — không khôi phục được"), contentsOnly: true, selected: false),
        ]

        let big = L("Dữ liệu lớn")
        specs += ScanKit.children(of: .homePath("Library/Application Support/MobileSync/Backup"), group: big,
                                  safety: .danger, note: L("Bản backup iPhone/iPad qua Finder"), selected: false,
                                  title: { L("Backup thiết bị \($0.lastPathComponent.prefix(8))…") })
        specs += [
            PathSpec(home: "Library/iTunes/iPhone Software Updates", L("File cập nhật iOS (.ipsw)"), group: big),
            PathSpec(home: "Library/iTunes/iPad Software Updates", L("File cập nhật iPadOS (.ipsw)"), group: big),
            PathSpec(home: "Library/Containers/com.apple.mail/Data/Library/Mail Downloads", "Mail Downloads", group: big,
                     safety: .caution, selected: false),
        ]

        var items = await ScanKit.measure(specs, minSize: 256 * 1024)

        // Needs admin rights (rm.md: sudo rm -rf /Library/Caches/* /Library/Logs/*)
        for (path, title) in [("/Library/Caches", L("/Library/Caches (hệ thống)")), ("/Library/Logs", L("/Library/Logs (hệ thống)"))] {
            let children = URL(fileURLWithPath: path).children().map(\.path)
            let size = await Task.detached { DiskUsage.size(ofPaths: children) }.value
            guard size > 0 else { continue }
            items.append(ScanKit.commandItem(
                id: "admin:\(path)", title: title, group: L("Cần quyền admin"),
                command: ShellCommand(executable: "/usr/bin/find",
                                      arguments: [path, "-mindepth", "1", "-maxdepth", "1", "-exec", "rm", "-rf", "{}", "+"],
                                      admin: true),
                size: size, safety: .caution,
                note: L("Sẽ hỏi mật khẩu admin. Dung lượng đo được có thể thiếu do không đủ quyền đọc."),
                selected: false, detail: "\(path)/*"))
        }

        var notes: [String] = []
        if !FileManager.default.isReadableFile(atPath: URL.homePath(".Trash").path)
            || (try? FileManager.default.contentsOfDirectory(atPath: URL.homePath(".Trash").path)) == nil {
            notes.append(L("Cấp quyền Full Disk Access cho OmitX để đo được Thùng rác, Mail, backup iPhone."))
        }
        notes.append(L("Các cache dev (pip, CocoaPods, Yarn...) trong ~/Library/Caches cũng xuất hiện ở module tương ứng — chỉ tính 1 lần."))
        return ScanResult(items: items, notes: notes)
    }
}
