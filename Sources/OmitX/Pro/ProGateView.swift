import SwiftUI

/// Code field and licensing buttons.
///
/// Shared by the gate screen and Settings: if buyers had to open a locked feature
/// to find where to enter their code, nobody would find it.
///
/// There is only **one** primary button, *Activate*. The move-to-this-Mac button appears only after the
/// server says the code is bound to another Mac — users cannot know that themselves
/// before trying, so showing both buttons up front only makes them guess.
struct LicenseControls: View {
    enum Style {
        /// Assistant panel / automation tab: centered, large buttons.
        case panel
        /// Inside the Settings form: label–value rows like every other setting.
        case form
    }

    var style: Style = .panel

    @State private var code = ""
    @State private var otp = ""
    @State private var busy = false
    @State private var error: String?
    @State private var emailHint: String?
    @State private var offerTransfer = false

    /// Code format hint, not translated — activation codes look the same in every language.
    private let mask = "XXXXX-XXXXX-XXXXX-XXXXX"
    private static let pricing = URL(string: "https://omitx.nviai.com/#pricing")!
    /// One-time price of Pro. Must match the Lemon Squeezy product. Formatted per locale
    /// ("$16.68", "16,68 $US"…) so changing it never means retranslating the buy link.
    private static let price = Decimal(string: "16.68")!.formatted(.currency(code: "USD"))

    @ViewBuilder
    var body: some View {
        switch style {
        case .panel: panel
        case .form: form
        }
    }

    // MARK: Layout

    private var panel: some View {
        VStack(spacing: 10) {
            if let emailHint {
                Text("Đã gửi mã xác nhận tới \(emailHint)")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Mã xác nhận", text: $otp)
                    .textFieldStyle(.roundedBorder).frame(width: 140).multilineTextAlignment(.center)
                Button("Xác nhận đổi máy", action: confirmTransfer)
                    .buttonStyle(.borderedProminent).disabled(busy || otp.isEmpty)
                Button("Huỷ", action: cancelTransfer).buttonStyle(.plain).font(.caption)
                if busy { ProgressView().controlSize(.small) }
                message
            } else {
                if Pro.state == .none {
                    Button("Dùng thử 14 ngày", action: startTrial)
                        .buttonStyle(.borderedProminent).disabled(busy)
                }
                TextField("Mã kích hoạt", text: $code, prompt: Text(verbatim: mask))
                    .textFieldStyle(.roundedBorder).frame(width: 220).multilineTextAlignment(.center)
                Button("Kích hoạt", action: activate).disabled(busy || code.isEmpty)
                if busy { ProgressView().controlSize(.small) }
                message
                if offerTransfer {
                    Button("Máy này là máy mới", action: requestTransfer).disabled(busy)
                }
                Link("Mua Pro — \(Self.price)", destination: Self.pricing)
                    .font(.callout)
            }
        }
    }

    /// The error sits right after the action that caused it — it explains the button that appears
    /// below it, so putting it at the bottom of the screen would read backwards.
    @ViewBuilder private var message: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var form: some View {
        if let emailHint {
            LabeledContent("Mã xác nhận") {
                HStack(spacing: 8) {
                    TextField("", text: $otp).textFieldStyle(.roundedBorder).frame(width: 90)
                    Button("Xác nhận đổi máy", action: confirmTransfer).disabled(busy || otp.isEmpty)
                    Button("Huỷ", action: cancelTransfer)
                }
            }
            Text("Đã gửi mã xác nhận tới \(emailHint)")
                .font(.caption).foregroundStyle(.secondary)
            message
        } else {
            LabeledContent("Mã kích hoạt") {
                HStack(spacing: 8) {
                    TextField("", text: $code, prompt: Text(verbatim: mask))
                        .textFieldStyle(.roundedBorder).frame(width: 235)
                    Button("Kích hoạt", action: activate).disabled(busy || code.isEmpty)
                }
            }
            message
            if offerTransfer {
                Button("Máy này là máy mới", action: requestTransfer).disabled(busy)
            }
            if Pro.state == .none {
                Button("Dùng thử 14 ngày", action: startTrial).disabled(busy)
            }
            Link("Mua Pro — \(Self.price)", destination: Self.pricing)
        }
    }

    // MARK: Actions

    private func activate() {
        run { try await Pro.license?.activate(code: code) }
    }

    private func startTrial() {
        run { try await Pro.license?.startTrial() }
    }

    private func requestTransfer() {
        run { emailHint = try await Pro.license?.requestTransfer(code: code) ?? "" }
    }

    private func confirmTransfer() {
        run { try await Pro.license?.confirmTransfer(code: code, otp: otp) } then: {
            emailHint = nil
            otp = ""
            offerTransfer = false
        }
    }

    private func cancelTransfer() {
        emailHint = nil
        otp = ""
        error = nil
    }

    private func run(_ work: @escaping () async throws -> Void,
                     then success: @escaping () -> Void = {}) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await work()
                success()
            } catch {
                self.error = error.localizedDescription
                // A code bound to another Mac is the only case that needs the second button — show it now.
                if (error as? LicenseFailure)?.code == "bound_elsewhere" { offerTransfer = true }
            }
        }
    }
}

/// Replacement screen shown while a Pro feature is locked.
struct ProGateView: View {
    enum Feature {
        case chat, automation

        var title: String {
            switch self {
            case .chat: L("Trợ lý là tính năng Pro")
            case .automation: L("Tự động hoá là tính năng Pro")
            }
        }
        var pitch: String {
            switch self {
            case .chat: L("Gõ yêu cầu thay vì tick từng mục. Trợ lý quét, chọn sẵn rồi mở bảng xác nhận cho bạn duyệt.")
            case .automation: L("Cảnh báo trước khi ổ cứng đầy và tự dọn theo quy tắc bạn đặt, kể cả khi đã đóng cửa sổ OmitX.")
            }
        }
    }

    let feature: Feature

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "lock.circle").font(.system(size: 34)).foregroundStyle(.secondary)
            Text(feature.title).font(.headline)
            Text(feature.pitch)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 20)

            status

            if Pro.isLinked {
                LicenseControls(style: .panel)
            } else {
                Text("Bản build này không kèm phần Pro.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
    }

    @ViewBuilder private var status: some View {
        switch Pro.state {
        case .trial(let days):
            Text("Đang dùng thử — còn \(days) ngày").font(.callout).foregroundStyle(.secondary)
        case .grace(let days):
            Text("Chưa liên lạc được máy chủ — còn dùng được \(days) ngày").font(.callout).foregroundStyle(.orange)
        case .expired:
            Text("Bản dùng thử đã hết hạn.").font(.callout).foregroundStyle(.secondary)
        case .revoked:
            Text("Mã này đã bị thu hồi.").font(.callout).foregroundStyle(.orange)
        case .none, .active:
            EmptyView()
        }
    }
}
