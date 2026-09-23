import SwiftUI

struct ModuleView: View {
    @Environment(AppState.self) private var state
    let moduleID: String
    @State private var search = ""
    @State private var safetyFilter: Safety?
    @State private var collapsed: Set<String> = []
    @State private var confirmItems: ConfirmPayload?

    var body: some View {
        let module = state.module(moduleID)
        let ms = state.state(moduleID)
        VStack(spacing: 0) {
            header(module, ms)
            Divider()
            if moduleID == ProjectModule.idValue {
                ProjectRootsBar()
                Divider()
            }
            content(ms)
            Divider()
            CleanBar(moduleIDs: [moduleID]) { confirmItems = ConfirmPayload(items: $0) }
        }
        .sheet(item: $confirmItems) { ConfirmCleanSheet(items: $0.items) }
        .task(id: moduleID) {
            if state.state(moduleID).status == .idle { await state.scan(moduleID) }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Lọc theo tên / đường dẫn")
    }

    @ViewBuilder
    private func header(_ module: (any CleanModule)?, _ ms: ModuleState) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: module?.icon ?? "questionmark")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(module?.title ?? moduleID).font(.title2.bold())
                Text(module?.summary ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteFormat.string(state.totalSize(moduleID))).font(.title2.bold()).monospacedDigit()
                Text(ms.scannedAt.map { L("Quét \($0.relative)") } ?? L("Chưa quét")).font(.caption).foregroundStyle(.secondary)
            }
            Button {
                Task { await state.scan(moduleID) }
            } label: {
                Label("Quét lại", systemImage: "arrow.clockwise")
            }
            .disabled(ms.status == .scanning || state.isCleaning)
        }
        .padding(16)
    }

    @ViewBuilder
    private func content(_ ms: ModuleState) -> some View {
        let items = filtered(ms.result.items)
        if ms.status == .scanning && ms.result.items.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Đang quét…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if ms.status == .idle {
            ContentUnavailableView {
                Label("Chưa quét", systemImage: "magnifyingglass")
            } actions: {
                Button("Quét ngay") { Task { await state.scan(moduleID) } }
            }
        } else {
            List {
                if !ms.result.notes.isEmpty {
                    Section {
                        ForEach(ms.result.notes, id: \.self) { NoteBanner(text: $0) }
                    }
                    .listRowSeparator(.hidden)
                }
                if ms.status == .scanning {
                    HStack { ProgressView().controlSize(.small); Text("Đang quét lại…").foregroundStyle(.secondary) }
                }
                safetyPicker
                if items.isEmpty {
                    Text(ms.result.items.isEmpty ? L("Không có gì để dọn 🎉") : L("Không có mục nào khớp bộ lọc"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(30)
                }
                ForEach(groups(items), id: \.name) { group in
                    Section {
                        if !collapsed.contains(group.name) {
                            ForEach(group.items) { ItemRow(item: $0) }
                        }
                    } header: {
                        groupHeader(group)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var safetyPicker: some View {
        Picker("Mức độ", selection: $safetyFilter) {
            Text("Tất cả").tag(Safety?.none)
            ForEach(Safety.allCases, id: \.self) { s in
                Label(s.label, systemImage: s.symbol).tag(Safety?.some(s))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 380)
        .listRowSeparator(.hidden)
    }

    private func groupHeader(_ group: ItemGroup) -> some View {
        let selected = group.items.filter { state.isSelected($0) }.count
        return HStack(spacing: 8) {
            TriStateCheckbox(selected: selected, total: group.items.count) { state.setSelected(group.items, $0) }
            Button {
                if collapsed.contains(group.name) { collapsed.remove(group.name) } else { collapsed.insert(group.name) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsed.contains(group.name) ? "chevron.right" : "chevron.down")
                        .font(.caption.bold()).foregroundStyle(.secondary).frame(width: 10)
                    Text(group.name).font(.headline).foregroundStyle(.primary)
                    Text("\(group.items.count)").font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).background(.quaternary, in: Capsule())
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Text(ByteFormat.string(group.total)).font(.callout.weight(.semibold)).monospacedDigit()
        }
        .padding(.vertical, 4)
    }

    struct ItemGroup { let name: String; let items: [CleanItem]; let total: Int64 }

    private func groups(_ items: [CleanItem]) -> [ItemGroup] {
        var order: [String] = []
        var map: [String: [CleanItem]] = [:]
        for item in items {
            if map[item.group] == nil { order.append(item.group) }
            map[item.group, default: []].append(item)
        }
        return order.map { name in
            let list = map[name] ?? []
            return ItemGroup(name: name, items: list, total: AppState.removeNested(list).reduce(0) { $0 + $1.size })
        }
    }

    private func filtered(_ items: [CleanItem]) -> [CleanItem] {
        items.filter { item in
            (safetyFilter == nil || item.safety == safetyFilter)
                && (search.isEmpty || item.title.localizedCaseInsensitiveContains(search)
                    || (item.detail ?? "").localizedCaseInsensitiveContains(search)
                    || item.group.localizedCaseInsensitiveContains(search))
        }
    }
}

struct ConfirmPayload: Identifiable {
    let id = UUID()
    let items: [CleanItem]
}

struct ItemRow: View {
    @Environment(AppState.self) private var state
    let item: CleanItem

    var body: some View {
        let selected = state.isSelected(item)
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: selected ? "checkmark.square.fill" : "square")
                .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .font(.body)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).fontWeight(.medium).lineLimit(1)
                if let detail = item.detail {
                    Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                if let note = item.note {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            if let date = item.lastModified {
                Text(date.relative).font(.caption).foregroundStyle(.secondary).fixedSize()
            }
            SafetyBadge(safety: item.safety)
            SizeText(bytes: item.size, unknownLabel: "?")
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { state.toggle(item) }
        .contextMenu {
            if let url = item.path {
                Button("Hiện trong Finder") { Finder.reveal(url) }
                Button("Copy đường dẫn") { Finder.copy(url.path) }
            }
            if case .command(let cmd) = item.action {
                Button("Copy lệnh") { Finder.copy(cmd.display) }
            }
        }
        .help(item.actionDescription)
    }
}

/// Bottom bar: selected total + clean button.
struct CleanBar: View {
    @Environment(AppState.self) private var state
    let moduleIDs: [String]?
    let onClean: ([CleanItem]) -> Void

    var body: some View {
        let selected = state.selectedItems(in: moduleIDs)
        let size = selected.reduce(0) { $0 + $1.size }
        let all = (moduleIDs ?? state.allModules.map(\.id)).flatMap { state.items($0) }
        HStack(spacing: 12) {
            Menu("Chọn") {
                Button("Chọn tất cả mục An toàn") { state.setSelected(all.filter { $0.safety == .safe }, true) }
                Button("Chọn mặc định") {
                    state.setSelected(all, false)
                    state.setSelected(all.filter(\.selectedByDefault), true)
                }
                Button("Chọn tất cả") { state.setSelected(all, true) }
                Divider()
                Button("Bỏ chọn tất cả") { state.setSelected(all, false) }
            }
            .fixedSize()
            Text("Đã chọn \(selected.count) mục").foregroundStyle(.secondary)
            Spacer()
            Text(ByteFormat.string(size)).font(.title3.bold()).monospacedDigit()
            Button {
                onClean(selected)
            } label: {
                Label("Dọn dẹp", systemImage: "trash")
                    .frame(minWidth: 90)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(selected.isEmpty || state.isCleaning)
            .keyboardShortcut(.delete, modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
