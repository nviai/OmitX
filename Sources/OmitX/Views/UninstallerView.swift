import SwiftUI
import AppKit

@MainActor
@Observable
final class UninstallerModel {
    enum SortKey: String, CaseIterable, Identifiable {
        case size, name, lastUsed
        var id: String { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .size: "Dung lượng"
            case .name: "Tên"
            case .lastUsed: "Lần dùng cuối"
            }
        }
    }

    var apps: [InstalledApp] = []
    var loading = false
    var selectedID: String?
    var leftovers: [CleanItem] = []
    var loadingLeftovers = false
    var checked: Set<String> = []
    var sort: SortKey = .size

    var selected: InstalledApp? { apps.first { $0.id == selectedID } }

    func sorted(_ list: [InstalledApp]) -> [InstalledApp] {
        switch sort {
        case .size: list.sorted { $0.size > $1.size }
        case .name: list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .lastUsed: list.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
        }
    }

    func load() async {
        loading = true
        apps = await Task.detached { await AppUninstaller.listApps() }.value
        loading = false
        if let id = selectedID, !apps.contains(where: { $0.id == id }) {
            selectedID = nil
            leftovers = []
        }
    }

    func select(_ id: String?) async {
        selectedID = id
        leftovers = []
        checked = []
        guard let app = selected else { return }
        loadingLeftovers = true
        let found = await Task.detached { await AppUninstaller.leftovers(for: app) }.value
        guard selectedID == app.id else { return }
        leftovers = found
        checked = Set(found.filter(\.selectedByDefault).map(\.id))
        loadingLeftovers = false
    }
}

struct UninstallerView: View {
    @Environment(AppState.self) private var state
    @State private var model = UninstallerModel()
    @State private var search = ""
    @State private var confirm: ConfirmPayload?

    var body: some View {
        HStack(spacing: 0) {
            appList
                .frame(width: 320)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .searchable(text: $search, placement: .toolbar, prompt: "Tìm ứng dụng")
        .task {
            guard model.apps.isEmpty else { return }
            await model.load()
#if DEBUG
            if let name = DebugLaunch.uninstallerApp,
               let app = model.apps.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                await model.select(app.id)
            }
#endif
        }
        .onChange(of: state.log.count) {
            Task {
                await model.load()
                await model.select(model.selectedID)
            }
        }
        .sheet(item: $confirm) { payload in
            let app = model.selected
            ConfirmCleanSheet(items: payload.items) {
                if let app { await AppUninstaller.quit(app) }
            }
        }
    }

    // MARK: App list

    private var filteredApps: [InstalledApp] {
        let list = search.isEmpty ? model.apps : model.apps.filter {
            $0.name.localizedCaseInsensitiveContains(search) || ($0.bundleID ?? "").localizedCaseInsensitiveContains(search)
        }
        return model.sorted(list)
    }

    private var appList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(filteredApps.count) ứng dụng")
                    .font(.headline)
                Spacer()
                Picker("Sắp xếp theo", selection: $model.sort) {
                    ForEach(UninstallerModel.SortKey.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                Button {
                    Task { await model.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.loading)
                .help("Quét lại")
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            Divider()

            if model.loading && model.apps.isEmpty {
                ProgressView("Đang đọc danh sách ứng dụng…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredApps, selection: Binding(
                    get: { model.selectedID },
                    set: { id in Task { await model.select(id) } })
                ) { app in
                    AppRow(app: app).tag(app.id)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(.background.secondary)
    }

    // MARK: App details

    @ViewBuilder
    private var detail: some View {
        if let app = model.selected {
            VStack(spacing: 0) {
                AppHeader(app: app, relatedSize: model.leftovers.filter { !$0.id.hasPrefix("app:") }.reduce(0) { $0 + $1.size })
                Divider()
                if model.loadingLeftovers {
                    ProgressView("Đang tìm file liên quan…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    leftoverList
                }
                Divider()
                bottomBar
            }
        } else {
            ContentUnavailableView("Chọn một ứng dụng", systemImage: "app.dashed",
                                   description: Text("OmitX sẽ tìm app cùng toàn bộ cache, cấu hình, container, log… mà nó để lại trong ~/Library."))
        }
    }

    private var groups: [(name: String, items: [CleanItem])] {
        var order: [String] = []
        var map: [String: [CleanItem]] = [:]
        for item in model.leftovers {
            if map[item.group] == nil { order.append(item.group) }
            map[item.group, default: []].append(item)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    private var leftoverList: some View {
        List {
            ForEach(groups, id: \.name) { group in
                Section {
                    ForEach(group.items) { item in
                        LeftoverRow(item: item, checked: model.checked.contains(item.id)) {
                            if model.checked.contains(item.id) { model.checked.remove(item.id) } else { model.checked.insert(item.id) }
                        }
                    }
                } header: {
                    let selected = group.items.filter { model.checked.contains($0.id) }.count
                    HStack(spacing: 8) {
                        TriStateCheckbox(selected: selected, total: group.items.count) { on in
                            let ids = group.items.map(\.id)
                            if on { model.checked.formUnion(ids) } else { model.checked.subtract(ids) }
                        }
                        Image(systemName: group.items.first?.id.hasPrefix("app:") == true ? "square.grid.2x2" : "folder")
                            .foregroundStyle(.secondary)
                        Text(group.name).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(ByteFormat.string(group.items.reduce(0) { $0 + $1.size }))
                            .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .listStyle(.inset)
    }

    private var bottomBar: some View {
        let items = model.leftovers.filter { model.checked.contains($0.id) }
        let includesApp = items.contains { $0.id.hasPrefix("app:") }
        let appOnly = items.count == 1 && includesApp
        return HStack(spacing: 12) {
            Text("Đã chọn \(items.count) mục")
                .foregroundStyle(.secondary)
            Spacer()
            Text(ByteFormat.string(items.reduce(0) { $0 + $1.size }))
                .font(.title3.bold()).monospacedDigit()
            Button {
                confirm = ConfirmPayload(items: items)
            } label: {
                Label(includesApp ? L("Gỡ cài đặt") : L("Xoá file đã chọn"), systemImage: "trash")
                    .frame(minWidth: 90)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(items.isEmpty || state.isCleaning)
            .help(appOnly ? L("Chỉ xoá app — nên chọn thêm file liên quan") : "")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct AppRow: View {
    let app: InstalledApp
    var body: some View {
        HStack(spacing: 10) {
            FileIcon(url: app.url, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(ByteFormat.string(app.size))
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let v = app.version { parts.append("v\(v)") }
        if let d = app.lastUsed { parts.append(d.relative) }
        return parts.isEmpty ? (app.bundleID ?? "") : parts.joined(separator: " · ")
    }
}

private struct AppHeader: View {
    let app: InstalledApp
    let relatedSize: Int64

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            FileIcon(url: app.url, size: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.title2.bold()).lineLimit(1)
                Text(app.bundleID ?? L("Không có bundle ID"))
                    .font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    if let v = app.version { Text(verbatim: "v\(v)") }
                    if let d = app.lastUsed { Text("·"); Text(L("Dùng lần cuối: \(d.relative)."))}
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                Text(ByteFormat.string(app.size + relatedSize)).font(.title2.bold()).monospacedDigit()
                Button("Hiện trong Finder") { Finder.reveal(app.url) }
                    .controlSize(.small)
            }
        }
        .padding(16)
    }
}

private struct LeftoverRow: View {
    let item: CleanItem
    let checked: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            if let url = item.path {
                FileIcon(url: url, size: 20)
            } else {
                // Items needing admin rights (run a command) — keep the icon column aligned
                Image(systemName: "lock.fill").foregroundStyle(.secondary).frame(width: 20, height: 20)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1).truncationMode(.middle)
                if let note = item.note {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            SafetyBadge(safety: item.safety)
            SizeText(bytes: item.size)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .contextMenu {
            if let url = item.path {
                Button("Hiện trong Finder") { Finder.reveal(url) }
                Button("Copy đường dẫn") { Finder.copy(url.path) }
            }
        }
        .help(item.detail ?? "")
    }
}
