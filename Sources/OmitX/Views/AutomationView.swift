import SwiftUI
import Observation

@MainActor
@Observable
final class AutomationModel {
    var settings: AutomationSettings
    var agent: AgentState
    var history: RunHistory
    /// Dry-run result of the rule open in the editor.
    var preview: (items: Int, bytes: Int64)?
    var previewing = false
    var error: String?

    init() {
        settings = .load()
        agent = Pro.automation?.agentState ?? .unavailable
        history = .load()
    }

    func save() {
        do { try settings.save() } catch { self.error = error.localizedDescription }
    }

    func refresh() {
        agent = Pro.automation?.agentState ?? .unavailable
        history = .load()
    }

    func setAgent(_ on: Bool) {
        do {
            try Pro.automation?.setAgent(on)
        } catch {
            self.error = error.localizedDescription
        }
        agent = Pro.automation?.agentState ?? .unavailable
    }

    func preview(_ rule: CleanRule, engine: EngineSettings) async {
        previewing = true
        defer { previewing = false }
        guard let plan = await Pro.automation?.plan(rule, settings: engine) else { return }
        preview = (plan.items.count, plan.bytes)
    }
}

/// Bytes shown and edited in GB.
private func gigabytes(_ bytes: Binding<Int64>) -> Binding<Double> {
    Binding(get: { Double(bytes.wrappedValue) / 1_000_000_000 },
            set: { bytes.wrappedValue = Int64($0 * 1_000_000_000) })
}

struct AutomationView: View {
    @Environment(AppState.self) private var state
    @State private var model = AutomationModel()
    @State private var editing: CleanRule?

    var body: some View {
        if Pro.isUnlocked { form } else { ProGateView(feature: .automation) }
    }

    private var form: some View {
        @Bindable var model = model
        return Form {
            Section {
                Toggle("Bật theo dõi & dọn tự động", isOn: $model.settings.enabled)
                    .onChange(of: model.settings.enabled) { _, on in
                        model.save()
                        if on { Task { await Pro.automation?.requestNotificationPermission() } }
                    }
                agentRow
            } header: {
                Text("Tiến trình nền")
            } footer: {
                Text("Tiến trình nền chạy ngay cả khi cửa sổ OmitX đã đóng — đó là điều kiện để cảnh báo trước khi ổ cứng đầy.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Cảnh báo khi còn dưới") {
                    HStack {
                        Slider(value: gigabytes($model.settings.warnBelowBytes), in: 5...200, step: 5)
                        Text(ByteFormat.string(model.settings.warnBelowBytes))
                            .monospacedDigit().frame(width: 70, alignment: .trailing)
                    }
                }
                LabeledContent("Chạy quy tắc khi còn dưới") {
                    HStack {
                        Slider(value: gigabytes($model.settings.actBelowBytes), in: 2...100, step: 2)
                        Text(ByteFormat.string(model.settings.actBelowBytes))
                            .monospacedDigit().frame(width: 70, alignment: .trailing)
                    }
                }
                Stepper("Kiểm tra mỗi \(model.settings.pollMinutes) phút",
                        value: $model.settings.pollMinutes, in: 1...120, step: 1)
                if let volume = state.volume {
                    DiskBar(total: volume.total, available: volume.available, reclaimable: state.grandTotal)
                        .padding(.top, 4)
                }
            } header: {
                Text("Ngưỡng dung lượng")
            } footer: {
                Text("macOS chỉ báo khi ổ đã gần cạn. Đặt ngưỡng cao hơn để còn kịp xử lý.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: model.settings.warnBelowBytes) { model.save() }
            .onChange(of: model.settings.actBelowBytes) { model.save() }
            .onChange(of: model.settings.pollMinutes) { model.save() }

            Section("Quy tắc") {
                if model.settings.rules.isEmpty {
                    Text("Chưa có quy tắc nào.").foregroundStyle(.secondary)
                }
                ForEach($model.settings.rules) { $rule in
                    RuleRow(rule: $rule, edit: { editing = rule },
                            remove: {
                                model.settings.rules.removeAll { $0.id == rule.id }
                                model.save()
                            },
                            toggled: { model.save() })
                }
                Button {
                    editing = CleanRule(name: L("Quy tắc mới"),
                                        trigger: .freeSpaceBelow(model.settings.actBelowBytes))
                } label: { Label("Thêm quy tắc", systemImage: "plus") }
            }

            if !model.history.runs.isEmpty {
                Section("Lần chạy gần đây") {
                    ForEach(model.history.runs.prefix(6)) { run in
                        HStack {
                            Image(systemName: run.executed ? "checkmark.circle.fill" : "bell")
                                .foregroundStyle(run.executed ? Color.green : .secondary)
                            VStack(alignment: .leading) {
                                Text(run.ruleName)
                                Text(run.date.relative).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            SizeText(bytes: run.executed ? run.freed : run.bytes)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { rule in
            RuleEditor(rule: rule) { saved in
                if let i = model.settings.rules.firstIndex(where: { $0.id == saved.id }) {
                    model.settings.rules[i] = saved
                } else {
                    model.settings.rules.append(saved)
                }
                model.save()
            }
            .environment(state)
        }
        .alert("Không thực hiện được", isPresented: Binding(get: { model.error != nil },
                                                            set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
        .onAppear { model.refresh() }
    }

    @ViewBuilder private var agentRow: some View {
        switch model.agent {
        case .unavailable:
            Label("Chạy bằng `swift run` nên chưa đăng ký được khởi động cùng máy. Cần bản build .app.",
                  systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
        case .requiresApproval:
            HStack {
                Label("Cần duyệt trong System Settings", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Mở Login Items") { Pro.automation?.openLoginItemsSettings() }
            }
        case .enabled, .disabled:
            Toggle("Khởi động cùng máy", isOn: Binding(get: { model.agent.isOn },
                                                        set: { model.setAgent($0) }))
        }
    }
}

private struct RuleRow: View {
    @Binding var rule: CleanRule
    let edit: () -> Void
    let remove: () -> Void
    let toggled: () -> Void

    var body: some View {
        HStack {
            Toggle("", isOn: $rule.enabled).labelsHidden()
                .onChange(of: rule.enabled) { toggled() }
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(rule.action.label).font(.caption)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(rule.action == .deleteNow ? Color.orange.opacity(0.15) : Color.secondary.opacity(0.12),
                            in: Capsule())
            Button("Sửa", action: edit)
            Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        let when: String = switch rule.trigger {
        case .freeSpaceBelow(let b): L("Khi còn dưới \(ByteFormat.string(b))")
        case .schedule(let s): s.weekday == nil
            ? L("Hằng ngày lúc \(String(format: "%02d:%02d", s.hour, s.minute))")
            : L("Hằng tuần lúc \(String(format: "%02d:%02d", s.hour, s.minute))")
        }
        let scope = rule.query.modules.isEmpty ? L("mọi hạng mục") : rule.query.modules.joined(separator: ", ")
        return "\(when) · \(scope)"
    }
}
