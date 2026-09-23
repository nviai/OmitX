import SwiftUI
import AppKit

@MainActor
func pickFolders(multiple: Bool = true) -> [URL] {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = multiple
    panel.directoryURL = .home
    panel.prompt = L("Chọn")
    return panel.runModal() == .OK ? panel.urls : []
}

struct ProjectRootsBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Quét trong:").foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(state.projectRoots, id: \.self) { url in
                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                Text(url.path.abbreviatingHome)
                                Button {
                                    state.projectRoots.removeAll { $0 == url }
                                } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                            .font(.callout)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                        }
                    }
                }
                Button {
                    for url in pickFolders() where !state.projectRoots.contains(url) { state.projectRoots.append(url) }
                } label: { Label("Thêm thư mục", systemImage: "plus") }
            }
            HStack(spacing: 16) {
                Stepper("Độ sâu tối đa: \(state.projectMaxDepth)", value: $state.projectMaxDepth, in: 2...15)
                    .fixedSize()
                Picker("Chọn sẵn project không đụng tới hơn", selection: $state.staleDays) {
                    Text("7 ngày").tag(7)
                    Text("30 ngày").tag(30)
                    Text("90 ngày").tag(90)
                    Text("180 ngày").tag(180)
                    Text("1 năm").tag(365)
                }
                .fixedSize()
                Spacer()
                Button("Áp dụng & quét lại") { Task { await state.scan(ProjectModule.idValue) } }
            }
            .font(.callout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("Chung", systemImage: "gearshape") }
            AutomationView()
                .tabItem { Label("Tự động", systemImage: "clock.arrow.circlepath") }
            LicenseTab()
                .tabItem { Label("Bản quyền Pro", systemImage: "key") }
        }
        .frame(width: 600, height: 640)
    }
}

struct GeneralSettings: View {
    @Environment(AppState.self) private var state
    @State private var userPATH = ""

    var body: some View {
        @Bindable var state = state
        Form {
            Section("Cách xoá") {
                Picker("Cách xoá file", selection: $state.deleteMode) {
                    ForEach(DeleteMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text("\"Xoá vĩnh viễn\" giải phóng dung lượng ngay. \"Thùng rác\" an toàn hơn nhưng phải dọn Thùng rác mới lấy lại dung lượng. Lệnh CLI (docker, brew, simctl) không bị ảnh hưởng bởi tuỳ chọn này.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LanguageSection()
            Section("Quét project") {
                ForEach(state.projectRoots, id: \.self) { url in
                    HStack {
                        Label(url.path.abbreviatingHome, systemImage: "folder")
                        Spacer()
                        Button("Xoá") { state.projectRoots.removeAll { $0 == url } }
                    }
                }
                Button("Thêm thư mục…") {
                    for url in pickFolders() where !state.projectRoots.contains(url) { state.projectRoots.append(url) }
                }
                Stepper("Độ sâu tối đa: \(state.projectMaxDepth)", value: $state.projectMaxDepth, in: 2...15)
                Stepper("Coi là \"cũ\" sau \(state.staleDays) ngày", value: $state.staleDays, in: 1...730, step: 7)
            }
            Section("Quyền truy cập") {
                Text("Để đo được Thùng rác, Mail, backup iPhone và dữ liệu của app khác, hãy cấp Full Disk Access cho OmitX.")
                    .font(.callout)
                Button("Mở cài đặt Full Disk Access") { Finder.openFullDiskAccessSettings() }
            }
            Section("Môi trường") {
                LabeledContent("PATH dùng để chạy lệnh") {
                    Text(userPATH).font(.caption.monospaced()).textSelection(.enabled).lineLimit(4)
                }
            }
        }
        .formStyle(.grouped)
        // `Shell.userPATH` runs a login shell (up to 8 seconds) on first read. Reading it
        // inside body would hang the main thread right as Settings opens, so load it in the background.
        .task {
            userPATH = await Task.detached { Shell.userPATH }.value
        }
    }
}

struct LicenseTab: View {
    var body: some View {
        Form { LicenseSection() }.formStyle(.grouped)
    }
}

/// Pro license status and the release-this-Mac button.
///
/// Users must be able to release a Mac themselves: sell the old Mac without releasing it and the
/// code stays stuck there until an OTP email lets them move it to the new one.
struct LicenseSection: View {
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Section("Bản quyền Pro") {
            LabeledContent("Tình trạng", value: summary)
            if let info = Pro.info {
                if !Pro.state.isTrial {
                    LabeledContent("Mã kích hoạt") {
                        Text(info.code).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
                LabeledContent("Kiểm lại trước", value: info.expires.formatted(date: .abbreviated, time: .omitted))
                LabeledContent("Mã máy", value: info.machineHint)
                Button("Nhả máy này") {
                    busy = true
                    error = nil
                    Task {
                        defer { busy = false }
                        do { try await Pro.license?.deactivate() }
                        catch { self.error = error.localizedDescription }
                    }
                }
                .disabled(busy)
                Text("Nhả máy này trước khi bán hoặc cài lại máy, để dùng mã ở máy khác mà không cần mã xác nhận.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // On a trial or nothing yet: the code must be enterable right here, instead of making
            // buyers hunt for a locked feature to find the field.
            if Pro.isLinked, Pro.state != .active {
                LicenseControls(style: .form)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var summary: String {
        switch Pro.state {
        case .none: Pro.isLinked ? L("Chưa kích hoạt") : L("Bản build này không kèm phần Pro.")
        case .trial(let days): L("Đang dùng thử — còn \(days) ngày")
        case .active: L("Đã kích hoạt")
        case .grace(let days): L("Chưa liên lạc được máy chủ — còn dùng được \(days) ngày")
        case .expired: L("Đã hết hạn")
        case .revoked: L("Mã này đã bị thu hồi.")
        }
    }
}

/// Picks the UI language (requires relaunching the app).
struct LanguageSection: View {
    @State private var selection: String = AppLanguage.override ?? ""
    @State private var changed = false

    var body: some View {
        Section("Ngôn ngữ") {
            Picker("Ngôn ngữ giao diện", selection: $selection) {
                Text("Theo hệ thống").tag("")
                Divider()
                ForEach(AppLanguage.available.sorted { AppLanguage.nativeName($0) < AppLanguage.nativeName($1) }, id: \.self) {
                    Text(AppLanguage.nativeName($0)).tag($0)
                }
            }
            .onChange(of: selection) {
                AppLanguage.override = selection.isEmpty ? nil : selection
                changed = true
            }
            if changed {
                HStack {
                    Text("Khởi động lại OmitX để áp dụng ngôn ngữ mới.").font(.callout)
                    Spacer()
                    Button("Khởi động lại") { AppLanguage.relaunch() }
                }
            }
        }
    }
}

/// The 🌐 toolbar menu for switching language quickly.
struct LanguageMenu: View {
    var body: some View {
        Menu {
            Button("Theo hệ thống") { apply(nil) }
            Divider()
            ForEach(AppLanguage.available.sorted { AppLanguage.nativeName($0) < AppLanguage.nativeName($1) }, id: \.self) { code in
                Button {
                    apply(code)
                } label: {
                    if code == AppLanguage.current { Label(AppLanguage.nativeName(code), systemImage: "checkmark") }
                    else { Text(AppLanguage.nativeName(code)) }
                }
            }
        } label: {
            Label("Ngôn ngữ", systemImage: "globe")
        }
        .help("Ngôn ngữ giao diện")
    }

    private func apply(_ code: String?) {
        AppLanguage.override = code
        AppLanguage.relaunch()
    }
}
