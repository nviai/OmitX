import SwiftUI

/// Creates or edits an automation rule, with a dry-run button before enabling it.
struct RuleEditor: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var rule: CleanRule
    @State private var isSchedule: Bool
    @State private var schedule: Schedule
    @State private var freeSpaceBytes: Int64
    @State private var capEnabled: Bool
    @State private var capBytes: Int64
    @State private var preview: RulePlan?
    @State private var previewing = false
    @State private var error: String?

    let onSave: (CleanRule) -> Void

    init(rule: CleanRule, onSave: @escaping (CleanRule) -> Void) {
        _rule = State(initialValue: rule)
        switch rule.trigger {
        case .schedule(let s):
            _isSchedule = State(initialValue: true)
            _schedule = State(initialValue: s)
            _freeSpaceBytes = State(initialValue: 20_000_000_000)
        case .freeSpaceBelow(let b):
            _isSchedule = State(initialValue: false)
            _schedule = State(initialValue: Schedule())
            _freeSpaceBytes = State(initialValue: b)
        }
        _capEnabled = State(initialValue: rule.maxBytesPerRun != nil)
        _capBytes = State(initialValue: rule.maxBytesPerRun ?? 20_000_000_000)
        self.onSave = onSave
    }

    private var composed: CleanRule {
        var r = rule
        r.trigger = isSchedule ? .schedule(schedule) : .freeSpaceBelow(freeSpaceBytes)
        r.maxBytesPerRun = capEnabled ? capBytes : nil
        return r
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Quy tắc") {
                    TextField("Tên", text: $rule.name)
                    Picker("Khi nào chạy", selection: $isSchedule) {
                        Text("Khi ổ cứng sắp đầy").tag(false)
                        Text("Theo lịch").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if isSchedule {
                        Picker("Lặp lại", selection: Binding(get: { schedule.weekday ?? 0 },
                                                             set: { schedule.weekday = $0 == 0 ? nil : $0 })) {
                            Text("Hằng ngày").tag(0)
                            ForEach(1...7, id: \.self) { Text(weekdayName($0)).tag($0) }
                        }
                        Stepper("Lúc \(String(format: "%02d:%02d", schedule.hour, schedule.minute))",
                                value: $schedule.hour, in: 0...23)
                    } else {
                        LabeledContent("Ngưỡng dung lượng trống") {
                            HStack {
                                Slider(value: Binding(get: { Double(freeSpaceBytes) / 1_000_000_000 },
                                                      set: { freeSpaceBytes = Int64($0 * 1_000_000_000) }),
                                       in: 2...100, step: 2)
                                Text(ByteFormat.string(freeSpaceBytes))
                                    .monospacedDigit().frame(width: 70, alignment: .trailing)
                            }
                        }
                    }
                }

                Section("Dọn cái gì") {
                    DisclosureGroup(rule.query.modules.isEmpty
                                    ? L("Mọi hạng mục")
                                    : L("\(rule.query.modules.count) hạng mục")) {
                        ForEach(state.allModules, id: \.id) { module in
                            Toggle(module.title, isOn: Binding(
                                get: { rule.query.modules.contains(module.id) },
                                set: { on in
                                    if on { rule.query.modules.append(module.id) }
                                    else { rule.query.modules.removeAll { $0 == module.id } }
                                }))
                        }
                    }
                    Toggle("Chỉ mục không đụng tới đã lâu", isOn: Binding(
                        get: { rule.query.staleDays != nil },
                        set: { rule.query.staleDays = $0 ? 30 : nil }))
                    if rule.query.staleDays != nil {
                        Picker("Cũ hơn", selection: Binding(get: { rule.query.staleDays ?? 30 },
                                                            set: { rule.query.staleDays = $0 })) {
                            Text("7 ngày").tag(7)
                            Text("30 ngày").tag(30)
                            Text("90 ngày").tag(90)
                            Text("180 ngày").tag(180)
                            Text("1 năm").tag(365)
                        }
                    }
                    Toggle("Giới hạn dung lượng mỗi lần chạy", isOn: $capEnabled)
                    if capEnabled {
                        LabeledContent("Tối đa") {
                            HStack {
                                Slider(value: Binding(get: { Double(capBytes) / 1_000_000_000 },
                                                      set: { capBytes = Int64($0 * 1_000_000_000) }),
                                       in: 1...200, step: 1)
                                Text(ByteFormat.string(capBytes))
                                    .monospacedDigit().frame(width: 70, alignment: .trailing)
                            }
                        }
                    }
                }

                Section {
                    Picker("Hành động", selection: $rule.action) {
                        ForEach(CleanRule.Action.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                } header: {
                    Text("Làm gì khi khớp")
                } footer: {
                    Text(rule.action.deletes
                         ? "Chạy không có người giám sát nên quy tắc chỉ đụng tới mục mức An toàn, bỏ qua mục cần mật khẩu admin và mục đang bị Xcode / emulator chiếm."
                         : "Chỉ gửi thông báo, không xoá gì.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Chạy thử") {
                    HStack {
                        Button {
                            Task {
                                previewing = true
                                preview = await Pro.automation?.plan(composed, settings: state.settings)
                                previewing = false
                            }
                        } label: {
                            Label("Xem quy tắc này dọn được gì", systemImage: "play.circle")
                        }
                        .disabled(previewing)
                        if previewing { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                    if let preview {
                        if preview.isEmpty {
                            Text("Ngay lúc này không có mục nào khớp.").foregroundStyle(.secondary)
                        } else {
                            HStack {
                                Text("Giải phóng ngay bây giờ")
                                Spacer()
                                SizeText(bytes: preview.bytes)
                                Text("· \(preview.items.count) mục").foregroundStyle(.secondary)
                            }
                            ForEach(preview.items.prefix(5)) { item in
                                HStack {
                                    Text(item.title).lineLimit(1)
                                    Spacer()
                                    SizeText(bytes: item.size)
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout).lineLimit(2)
                }
                Spacer()
                Button("Huỷ") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Lưu") {
                    do {
                        onSave(try composed.validated())
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(.bar)
        }
        .frame(width: 560, height: 620)
    }

    private func weekdayName(_ index: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        return symbols.indices.contains(index - 1) ? symbols[index - 1] : "\(index)"
    }
}
