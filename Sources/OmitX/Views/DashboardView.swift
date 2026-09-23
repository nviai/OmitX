import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) private var state
    @Binding var selection: SidebarItem?
    @State private var confirmItems: ConfirmPayload?

    private let columns = [GridItem(.adaptive(minimum: 230), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hero
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(state.allModules, id: \.id) { m in
                            ModuleCard(module: m) { selection = .module(m.id) }
                        }
                    }
                }
                .padding(20)
            }
            Divider()
            CleanBar(moduleIDs: nil) { confirmItems = ConfirmPayload(items: $0) }
        }
        .sheet(item: $confirmItems) { ConfirmCleanSheet(items: $0.items) }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dọn dẹp máy Mac cho developer").font(.largeTitle.bold())
                    Text("Quét cache, build artifact, SDK, simulator, Docker… rồi chọn những gì muốn xoá.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await state.scanAll() }
                } label: {
                    Label(state.isScanningAny ? L("Đang quét…") : L("Quét tất cả"), systemImage: "sparkle.magnifyingglass")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(state.isScanningAny || state.isCleaning)
                .keyboardShortcut("r", modifiers: .command)
            }
            if let v = state.volume {
                DiskBar(total: v.total, available: v.available, reclaimable: state.grandTotal)
            }
            HStack(spacing: 24) {
                stat("Có thể dọn", ByteFormat.string(state.grandTotal), .green)
                stat("Đã chọn", ByteFormat.string(state.selectedSize()), .red)
                if let last = state.log.first {
                    stat("Lần dọn gần nhất", "\(ByteFormat.string(last.freed)) · \(last.date.relative)", .blue)
                }
            }
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }

    private func stat(_ label: LocalizedStringKey, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).monospacedDigit().foregroundStyle(color)
        }
    }
}

struct ModuleCard: View {
    @Environment(AppState.self) private var state
    let module: any CleanModule
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        let ms = state.state(module.id)
        let total = state.totalSize(module.id)
        let selected = state.selectedSize(in: [module.id])
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: module.icon)
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 36, height: 36)
                        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    Spacer()
                    switch ms.status {
                    case .scanning: ProgressView().controlSize(.small)
                    case .idle: Text("Chưa quét").font(.caption).foregroundStyle(.secondary)
                    case .done:
                        Text(ByteFormat.string(total)).font(.title3.bold()).monospacedDigit()
                            .foregroundStyle(total > 1_000_000_000 ? .primary : .secondary)
                    }
                }
                Text(module.title).font(.headline)
                Text(module.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack {
                    if ms.status == .done {
                        Text("\(ms.result.items.count) mục").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if selected > 0 {
                            Text("Đã chọn \(ByteFormat.string(selected))").font(.caption.bold()).foregroundStyle(.red)
                        }
                    }
                }
            }
            .padding(14)
            .frame(height: 168)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hover ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Quét lại") { Task { await state.scan(module.id) } }
        }
    }
}
