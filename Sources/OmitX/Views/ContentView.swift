import SwiftUI

enum SidebarItem: Hashable {
    case dashboard
    case module(String)
    case uninstaller
    case analyzer
    case log
}

struct ContentView: View {
    @Environment(AppState.self) private var state
    @State private var selection: SidebarItem?
    /// Items proposed by the assistant, waiting for the user's approval in ConfirmCleanSheet.
    @State private var chatConfirm: ConfirmPayload?
    @AppStorage("showChat") private var showChat = false

    init(initialSelection: SidebarItem = .dashboard) {
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            // Lowered from 640 to 480: the assistant panel takes ~320pt more width.
            detail
                .frame(minWidth: 480, minHeight: 480)
        }
        .inspector(isPresented: $showChat) {
            ChatPanel(onPropose: { chatConfirm = ConfirmPayload(items: $0) })
                .inspectorColumnWidth(min: 300, ideal: 340, max: 480)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { LanguageMenu() }
            // Always show the button: when the assistant is unavailable, the panel is the only place
            // that explains why and offers a button to open System Settings.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showChat.toggle()
                } label: {
                    Label("Trợ lý", systemImage: "sparkles")
                }
                .help(L("Hiện/ẩn panel trợ lý"))
            }
        }
        .overlay {
            if state.isCleaning { CleaningOverlay() }
        }
        .sheet(item: Binding(get: { state.lastLog }, set: { state.lastLog = $0 })) { CleanResultSheet(entry: $0) }
        .sheet(item: $chatConfirm) { ConfirmCleanSheet(items: $0.items) }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Label("Tổng quan", systemImage: "gauge.with.dots.needle.67percent").tag(SidebarItem.dashboard)

            Section("Hạng mục dọn dẹp") {
                ForEach(state.cleanModules, id: \.id) { m in
                    sidebarRow(m).tag(SidebarItem.module(m.id))
                }
            }
            Section("Công cụ") {
                sidebarRow(state.projectModule).tag(SidebarItem.module(ProjectModule.idValue))
                Label("Gỡ ứng dụng", systemImage: "xmark.app").tag(SidebarItem.uninstaller)
                Label("Phân tích dung lượng", systemImage: "chart.bar.xaxis").tag(SidebarItem.analyzer)
                Label("Nhật ký", systemImage: "clock.arrow.circlepath").tag(SidebarItem.log)
            }
        }
        .listStyle(.sidebar)
    }

    private func sidebarRow(_ m: any CleanModule) -> some View {
        let ms = state.state(m.id)
        return HStack {
            Label(m.title, systemImage: m.icon)
            Spacer()
            if ms.status == .scanning {
                ProgressView().controlSize(.mini)
            } else if ms.status == .done {
                Text(ByteFormat.string(state.totalSize(m.id)))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .dashboard, .none: DashboardView(selection: $selection)
        case .module(let id): ModuleView(moduleID: id).id(id)
        case .uninstaller: UninstallerView()
        case .analyzer: DiskAnalyzerView()
        case .log: LogView()
        }
    }
}

extension CleanLogEntry: Equatable {
    static func == (a: CleanLogEntry, b: CleanLogEntry) -> Bool { a.id == b.id }
}

struct LogView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.log.isEmpty {
            ContentUnavailableView("Chưa dọn gì trong phiên này", systemImage: "clock")
        } else {
            List {
                ForEach(state.log) { entry in
                    Section {
                        ForEach(entry.outcomes) { o in
                            HStack {
                                Image(systemName: o.error == nil ? "checkmark.circle" : "xmark.circle")
                                    .foregroundStyle(o.error == nil ? .green : .red)
                                VStack(alignment: .leading) {
                                    Text(o.item.title)
                                    Text(o.error ?? o.item.actionDescription).font(.caption)
                                        .foregroundStyle(o.error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                                        .lineLimit(2)
                                }
                                Spacer()
                                SizeText(bytes: o.freed)
                            }
                        }
                    } header: {
                        HStack {
                            Text(entry.date.formatted(date: .abbreviated, time: .standard))
                            Spacer()
                            Text("Giải phóng \(ByteFormat.string(entry.freed))").monospacedDigit()
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}
