import Foundation

struct HomebrewModule: CleanModule {
    let id = "homebrew"
    let title = "Homebrew"
    let icon = "mug.fill"
    let summary = L("brew cleanup (bản cũ + download cache), brew autoremove (dependency mồ côi)")

    func scan() async -> ScanResult {
        guard Shell.has("brew") else { return ScanResult(notes: [L("Chưa cài Homebrew.")]) }
        var items: [CleanItem] = []

        // Dry run to learn how much space will really be freed
        if let r = try? await Shell.runAsync("brew", ["cleanup", "--prune=all", "-n"], timeout: 180) {
            let out = r.combined
            let size = Self.parseFreeSize(out)
            let count = out.split(separator: "\n").filter { $0.hasPrefix("Would remove") }.count
            if size > 0 || count > 0 {
                items.append(ScanKit.commandItem(
                    id: "cmd:brew-cleanup", title: "brew cleanup --prune=all", group: "Homebrew",
                    command: ShellCommand(executable: "brew", arguments: ["cleanup", "--prune=all"]),
                    size: size, note: L("Xoá phiên bản cũ của formula/cask và toàn bộ file tải về trong cache"),
                    detail: L("\(count) mục sẽ bị xoá")))
            }
        }

        if let r = try? await Shell.runAsync("brew", ["autoremove", "-n"], timeout: 120) {
            let formulae = r.stdout.split(separator: "\n").filter { !$0.hasPrefix("==>") && !$0.isEmpty }
            if !formulae.isEmpty {
                items.append(ScanKit.commandItem(
                    id: "cmd:brew-autoremove", title: "brew autoremove", group: "Homebrew",
                    command: ShellCommand(executable: "brew", arguments: ["autoremove"]),
                    safety: .caution,
                    note: L("Gỡ dependency không còn formula nào cần: \(formulae.prefix(12).joined(separator: ", "))\(formulae.count > 12 ? "…" : "")"),
                    detail: "\(formulae.count) formula"))
            }
        }

        items += await ScanKit.measure([
            PathSpec(home: "Library/Logs/Homebrew", "Homebrew logs", group: "Homebrew"),
        ])
        return ScanResult(items: items, notes: [L("Các formula lớn nhất: xem mục \"Phân tích dung lượng\" → /opt/homebrew/Cellar.")])
    }

    /// "==> This operation would free approximately 1.2GB of disk space."
    static func parseFreeSize(_ text: String) -> Int64 {
        guard let range = text.range(of: "free approximately ") else { return 0 }
        let rest = text[range.upperBound...]
        let token = rest.split(separator: " ").first.map(String.init) ?? ""
        return ByteFormat.parse(token)
    }
}
