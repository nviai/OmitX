import SwiftUI
import AppKit

struct DiskEntry: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let isDirectory: Bool
    let modified: Date?
    var size: Int64?

    // Sort keys for the Table (non-optional)
    var sortSize: Int64 { size ?? -1 }
    var sortDate: Date { modified ?? .distantPast }
}

@MainActor
@Observable
final class AnalyzerModel {
    var current: URL?
    var entries: [DiskEntry] = []
    var pending = 0
    var back: [URL] = []
    var sortOrder = [KeyPathComparator(\DiskEntry.sortSize, order: .reverse)]
    private var task: Task<Void, Never>?

    var total: Int64 { entries.reduce(0) { $0 + ($1.size ?? 0) } }
    var largest: Int64 { max(entries.compactMap(\.size).max() ?? 1, 1) }

    func open(_ url: URL, pushHistory: Bool = true) {
        if pushHistory, let current, current != url { back.append(current) }
        task?.cancel()
        current = url
        let children = url.children()
        entries = children.map {
            DiskEntry(url: $0, name: FileManager.default.displayName(atPath: $0.path),
                      isDirectory: $0.isDirectory && !DiskUsage.isSymlink($0.path), modified: $0.modificationDate)
        }
        pending = entries.count
        sort()
        task = Task { [weak self] in
            await withTaskGroup(of: (String, Int64).self) { group in
                var next = 0
                func add() {
                    guard next < children.count else { return }
                    let u = children[next]; next += 1
                    group.addTask { (u.path, DiskUsage.size(of: u)) }
                }
                for _ in 0..<min(6, children.count) { add() }
                for await (path, size) in group {
                    if Task.isCancelled { group.cancelAll(); return }
                    guard let self else { return }
                    if let i = self.entries.firstIndex(where: { $0.id == path }) { self.entries[i].size = size }
                    self.pending -= 1
                    if self.pending % 8 == 0 || self.pending == 0 { self.sort() }
                    add()
                }
            }
        }
    }

    func goBack() {
        guard let prev = back.popLast() else { return }
        open(prev, pushHistory: false)
    }

    func refresh() { if let current { open(current, pushHistory: false) } }

    func sort() { entries.sort(using: sortOrder) }
}

/// Locations worth checking often.
struct QuickLocation: Identifiable {
    var id: String { url.path }
    let url: URL
    let icon: String
    var title: String? = nil
    var name: String { title ?? FileManager.default.displayName(atPath: url.path) }

    static let all: [QuickLocation] = [
        QuickLocation(url: .home, icon: "house"),
        QuickLocation(url: .homePath("Library"), icon: "building.columns"),
        QuickLocation(url: .homePath("Library/Application Support"), icon: "shippingbox"),
        QuickLocation(url: .homePath("Library/Caches"), icon: "internaldrive"),
        QuickLocation(url: .homePath("Library/Containers"), icon: "cube"),
        QuickLocation(url: .homePath("Library/Developer"), icon: "hammer"),
        QuickLocation(url: URL(fileURLWithPath: "/Applications"), icon: "square.grid.2x2"),
        QuickLocation(url: URL(fileURLWithPath: "/opt/homebrew"), icon: "mug", title: "Homebrew"),
        QuickLocation(url: URL(fileURLWithPath: "/Library"), icon: "externaldrive"),
    ].filter { $0.url.isDirectory }
}

struct DiskAnalyzerView: View {
    @State private var model = AnalyzerModel()
    @State private var selection: Set<DiskEntry.ID> = []
    @State private var trashTarget: DiskEntry?
    @State private var errorText: String?

    var body: some View {
        Group {
            if model.current == nil {
                locationPicker
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    table
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
#if DEBUG
            if model.current == nil, let folder = DebugLaunch.analyzerFolder { model.open(folder) }
#endif
        }
        .alert("Chuyển vào Thùng rác?", isPresented: Binding(get: { trashTarget != nil }, set: { if !$0 { trashTarget = nil } }),
               presenting: trashTarget) { entry in
            Button("Chuyển vào Thùng rác", role: .destructive) {
                Task {
                    do {
                        try await Cleaner.remove(entry.url, mode: .trash)
                        model.refresh()
                    } catch { errorText = error.localizedDescription }
                }
            }
            Button("Huỷ", role: .cancel) {}
        } message: { entry in
            Text("\(entry.url.path)\n\(entry.size.map(ByteFormat.string) ?? "")")
        }
        .alert("Không xoá được", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") {}
        } message: { Text(errorText ?? "") }
    }

    // MARK: Location picker

    private var locationPicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Chọn một thư mục để phân tích").font(.title2.bold())
                    Text("Xem thư mục nào đang chiếm nhiều dung lượng nhất, bấm đúp để đi sâu vào.")
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(QuickLocation.all) { loc in
                        LocationCard(icon: loc.icon, title: loc.name, subtitle: loc.url.path.abbreviatingHome) {
                            model.open(loc.url)
                        }
                    }
                    LocationCard(icon: "folder.badge.plus", title: L("Chọn…"), subtitle: "") {
                        if let u = pickFolders(multiple: false).first { model.open(u) }
                    }
                }
            }
            .padding(24)
        }
    }

    // MARK: Header: navigation + total

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ControlGroup {
                    Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                        .disabled(model.back.isEmpty)
                        .help("Quay lại")
                    Button {
                        if let c = model.current { model.open(c.deletingLastPathComponent()) }
                    } label: { Image(systemName: "chevron.up") }
                        .disabled(model.current?.path == "/")
                        .help("Thư mục cha")
                }
                .fixedSize()
                breadcrumb
                Spacer(minLength: 8)
                Menu {
                    ForEach(QuickLocation.all) { loc in
                        Button { model.open(loc.url) } label: { Label(loc.name, systemImage: loc.icon) }
                    }
                    Divider()
                    Button("Chọn…") { if let u = pickFolders(multiple: false).first { model.open(u) } }
                } label: {
                    Label("Vị trí", systemImage: "folder")
                }
                .fixedSize()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Quét lại")
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(ByteFormat.string(model.total)).font(.title.bold()).monospacedDigit()
                Text("\(model.entries.count) mục").foregroundStyle(.secondary)
                Spacer()
                if model.pending > 0 {
                    ProgressView(value: Double(model.entries.count - model.pending), total: Double(max(model.entries.count, 1)))
                        .frame(width: 140)
                    Text("Đang tính dung lượng…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Path as clickable segments: Macintosh HD › Users › phale › Library
    private var breadcrumb: some View {
        let comps = pathComponents(model.current)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(comps.enumerated()), id: \.offset) { i, url in
                        if i > 0 { Image(systemName: "chevron.forward").font(.caption2).foregroundStyle(.tertiary) }
                        Button {
                            model.open(url)
                        } label: {
                            HStack(spacing: 4) {
                                FileIcon(url: url, size: 16)
                                Text(FileManager.default.displayName(atPath: url.path)).lineLimit(1)
                            }
                            .padding(.horizontal, 5).padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .fontWeight(i == comps.count - 1 ? .semibold : .regular)
                        .id(i)
                    }
                }
            }
            .onAppear { proxy.scrollTo(comps.count - 1, anchor: .trailing) }
            .onChange(of: model.current) { proxy.scrollTo(comps.count - 1, anchor: .trailing) }
        }
    }

    private func pathComponents(_ url: URL?) -> [URL] {
        guard let url else { return [] }
        var list: [URL] = []
        var u = url.standardizedFileURL
        while true {
            list.insert(u, at: 0)
            if u.path == "/" { break }
            u = u.deletingLastPathComponent()
        }
        return list
    }

    // MARK: Table

    private var table: some View {
        let total = max(model.total, 1)
        let largest = model.largest
        return Table(model.entries, selection: $selection, sortOrder: $model.sortOrder) {
            TableColumn("Tên", value: \.name) { e in
                HStack(spacing: 8) {
                    FileIcon(url: e.url, size: 18)
                    Text(e.name).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 180, ideal: 320)

            TableColumn("Dung lượng", value: \.sortSize) { e in
                HStack(spacing: 10) {
                    ProportionBar(fraction: Double(e.size ?? 0) / Double(largest))
                    Group {
                        if let s = e.size {
                            Text(percent(s, of: total))
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                            Text(ByteFormat.string(s))
                                .fontWeight(s >= 1_000_000_000 ? .semibold : .regular)
                                .frame(width: 76, alignment: .trailing)
                        } else {
                            ProgressView().controlSize(.mini)
                                .frame(width: 124, alignment: .trailing)
                        }
                    }
                    .monospacedDigit()
                }
            }
            .width(min: 220, ideal: 340)

            TableColumn("Ngày sửa", value: \.sortDate) { e in
                Text(e.modified?.relative ?? "—").foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 120)
        }
        .onChange(of: model.sortOrder) { model.sort() }
        .contextMenu(forSelectionType: DiskEntry.ID.self) { ids in
            if let entry = entry(ids) {
                if entry.isDirectory { Button("Mở") { model.open(entry.url) } }
                Button("Hiện trong Finder") { Finder.reveal(entry.url) }
                Button("Copy đường dẫn") { Finder.copy(entry.url.path) }
                Divider()
                Button("Chuyển vào Thùng rác…", role: .destructive) { trashTarget = entry }
            }
        } primaryAction: { ids in
            guard let entry = entry(ids) else { return }
            if entry.isDirectory { model.open(entry.url) } else { NSWorkspace.shared.open(entry.url) }
        }
    }

    private func entry(_ ids: Set<DiskEntry.ID>) -> DiskEntry? {
        guard let id = ids.first else { return nil }
        return model.entries.first { $0.id == id }
    }

    private func percent(_ size: Int64, of total: Int64) -> String {
        (Double(size) / Double(total)).formatted(.percent.precision(.fractionLength(0)))
    }
}

private struct LocationCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 36, height: 36)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hover ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
