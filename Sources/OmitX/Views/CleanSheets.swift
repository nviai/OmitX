import SwiftUI

struct ConfirmCleanSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let items: [CleanItem]
    /// Runs before cleaning (e.g. quitting the app when uninstalling).
    var beforeClean: (() async -> Void)? = nil

    @State private var acknowledged = false
    @State private var blockers: [String] = []

    private var dangerous: [CleanItem] { items.filter { $0.safety == .danger } }
    private var caution: [CleanItem] { items.filter { $0.safety == .caution } }
    private var hasPaths: Bool { items.contains { !$0.paths.isEmpty } }
    private var needsAdmin: Bool {
        items.contains { if case .command(let c) = $0.action { return c.admin }; return false }
    }

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "trash.circle.fill").font(.system(size: 36)).foregroundStyle(.red)
                VStack(alignment: .leading) {
                    Text("Dọn \(items.count) mục").font(.title2.bold())
                    Text("Giải phóng khoảng \(ByteFormat.string(items.reduce(0) { $0 + $1.size }))")
                        .foregroundStyle(.secondary)
                }
            }

            if !dangerous.isEmpty {
                warningBox(.red, L("\(dangerous.count) mục NGUY HIỂM — có thể mất dữ liệu thật"),
                           dangerous.map(\.title).joined(separator: ", "))
            }
            if !caution.isEmpty {
                warningBox(.orange, L("\(caution.count) mục cần cân nhắc"), L("Sẽ phải tải/build lại, hoặc mất cấu hình phụ."))
            }
            if !blockers.isEmpty {
                warningBox(.orange, L("Đang chạy: \(blockers.joined(separator: ", "))"),
                           L("Nên tắt các ứng dụng này trước để tránh lỗi hoặc file bị tạo lại ngay."))
            }
            if needsAdmin {
                Label("Một số mục cần quyền admin — macOS sẽ hỏi mật khẩu.", systemImage: "lock.shield")
                    .font(.callout).foregroundStyle(.secondary)
            }

            List(items) { item in
                HStack {
                    Image(systemName: item.safety.symbol).foregroundStyle(item.safety.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).lineLimit(1)
                        Text(item.actionDescription).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    SizeText(bytes: item.size, unknownLabel: "?")
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 160, maxHeight: 320)

            if hasPaths {
                Picker("Cách xoá", selection: $state.deleteMode) {
                    ForEach(DeleteMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
            }

            if !dangerous.isEmpty {
                Toggle("Tôi hiểu các mục nguy hiểm sẽ bị xoá và không khôi phục được", isOn: $acknowledged)
            }

            HStack {
                Spacer()
                Button("Huỷ", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    let items = self.items
                    let before = beforeClean
                    dismiss()
                    Task {
                        await before?()
                        await state.clean(items)
                    }
                } label: {
                    Text("Dọn dẹp").frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!dangerous.isEmpty && !acknowledged)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task {
            let names = Set(items.flatMap(\.blockingProcesses))
            blockers = await Task.detached { names.filter { Shell.isRunning($0) }.sorted() }.value
        }
    }

    private func warningBox(_ color: Color, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: "exclamationmark.triangle.fill").font(.callout.bold()).foregroundStyle(color)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct CleaningOverlay: View {
    @Environment(AppState.self) private var state
    var body: some View {
        let p = state.cleanProgress
        VStack(spacing: 14) {
            ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                .frame(width: 320)
            Text("Đang dọn \(min(p.done + 1, p.total))/\(p.total)").font(.headline)
            Text(p.current).font(.callout).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 320)
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.15))
    }
}

struct CleanResultSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: CleanLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: entry.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(entry.failures.isEmpty ? .green : .orange)
                VStack(alignment: .leading) {
                    Text("Đã giải phóng \(ByteFormat.string(entry.freed))").font(.title2.bold())
                    Text("\(entry.outcomes.count - entry.failures.count)/\(entry.outcomes.count) mục thành công")
                        .foregroundStyle(.secondary)
                }
            }
            List(entry.outcomes) { o in
                HStack(alignment: .top) {
                    Image(systemName: o.error == nil ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(o.error == nil ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(o.item.title)
                        if let e = o.error { Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                        if let out = o.output, !out.isEmpty {
                            Text(out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))
                                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(4)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                    SizeText(bytes: o.freed)
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 160, maxHeight: 360)
            HStack {
                Spacer()
                Button("Xong") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
