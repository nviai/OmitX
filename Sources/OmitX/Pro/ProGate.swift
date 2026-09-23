import Foundation

/// The boundary between the community build and Pro.
///
/// The public repository holds only protocols and data models; the implementation lives in the
/// closed-source `OmitXPro` package. Without that package everything here stays `nil` and
/// the Pro screens show an activation prompt.

// MARK: - License state

enum LicenseState: Equatable, Sendable {
    /// Not activated, no trial yet.
    case none
    case trial(daysLeft: Int)
    case active
    /// The token expired but the server could not be reached — keep working for a little longer.
    case grace(daysLeft: Int)
    case expired
    /// Revoked (refund, chargeback).
    case revoked

    var unlocksPro: Bool {
        switch self {
        case .active, .trial, .grace: true
        case .none, .expired, .revoked: false
        }
    }

    var isTrial: Bool { if case .trial = self { true } else { false } }
}

/// Display information about the current license. Contains nothing secret.
struct LicenseInfo: Equatable, Sendable {
    /// The activation code, or "trial" for a trial.
    var code: String
    var plan: String
    var expires: Date
    /// First 8 characters of the machine ID — enough for support, without identifying the Mac.
    var machineHint: String
}

/// Observable box so SwiftUI redraws when the state changes.
///
/// The Pro implementation writes here; public views only read it through `Pro.state`.
@Observable
@MainActor
final class LicenseStatus {
    static let shared = LicenseStatus()
    var state: LicenseState = .none
    var info: LicenseInfo?
}

/// A licensing error. `code` is a stable error code (from the server or the app); the
/// displayed text is translated here — the public repository owns every UI string.
struct LicenseFailure: LocalizedError, Equatable {
    let code: String
    /// The server's message; used only when the app does not know that error code.
    var serverMessage: String?

    var errorDescription: String? {
        switch code {
        case "network": L("Không liên lạc được máy chủ. Kiểm tra mạng rồi thử lại.")
        case "unknown_code": L("Mã kích hoạt không tồn tại.")
        case "revoked", "disabled": L("Mã này đã bị thu hồi.")
        case "bound_elsewhere": L("Mã này đang dùng trên máy khác.")
        case "too_many_machines": L("Mã này đã dùng trên quá nhiều máy. Hãy liên hệ hỗ trợ.")
        case "not_bound": L("Máy này không còn gắn với mã.")
        case "trial_used": L("Máy này đã dùng hết bản dùng thử.")
        case "trial_expired": L("Bản dùng thử đã hết hạn.")
        case "no_challenge": L("Chưa yêu cầu đổi máy.")
        case "otp_wrong": L("Mã xác nhận không đúng.")
        case "otp_expired": L("Mã xác nhận đã hết hạn.")
        case "otp_locked": L("Sai quá nhiều lần. Hãy yêu cầu mã mới.")
        case "bad_token", "wrong_machine": L("Giấy phép không dùng được trên máy này.")
        case "no_key": L("Bản build này chưa có khoá kiểm giấy phép.")
        default: serverMessage ?? L("Không kích hoạt được (\(code)).")
        }
    }
}

@MainActor
protocol LicenseGate: AnyObject {
    /// Local check at launch; only goes online when the token is about to expire or missing.
    func refresh() async
    func activate(code: String) async throws
    func startTrial() async throws
    /// Returns the order's masked email, so the user knows which inbox to check.
    func requestTransfer(code: String) async throws -> String
    func confirmTransfer(code: String, otp: String) async throws
    /// Releases this Mac so the code can be used on another one.
    func deactivate() async throws
}

// MARK: - Assistant

@MainActor
protocol ChatEngine: AnyObject {
    var availability: ChatAvailability { get }
    func refreshAvailability()
    /// Connects the engine to the app. `onPropose` opens the confirmation sheet in Propose mode.
    func bind(state: AppState, onPropose: @escaping ([CleanItem]) -> Void)
    func setMode(_ mode: ChatMode)
    /// Answers one turn. `note` lets the engine report internal events (e.g. the context was reset).
    func respond(to text: String, note: @MainActor (String) -> Void) async throws -> String
    /// Starts a new conversation.
    func reset()
    /// Starts a new conversation seeded with a saved one, so the assistant remembers it.
    /// Returns false when the engine cannot (the UI then says the assistant does not remember).
    func restore(_ messages: [ChatMessage]) -> Bool
}

// MARK: - Automation

/// Registration state of the background agent. Decoupled from `SMAppService` so the public repository does not need it.
enum AgentState: Equatable, Sendable {
    case enabled
    case disabled
    /// Registered, but not yet approved by the user in System Settings.
    case requiresApproval
    /// Running via `swift run`, without an .app bundle.
    case unavailable

    var isOn: Bool { self == .enabled }
}

@MainActor
protocol AutomationEngine: AnyObject {
    var agentState: AgentState { get }
    func setAgent(_ on: Bool) throws
    func openLoginItemsSettings()
    func requestNotificationPermission() async
    /// Dry-runs a rule; deletes nothing.
    func plan(_ rule: CleanRule, settings: EngineSettings) async -> RulePlan
}

// MARK: - Registry

@MainActor
enum Pro {
    static var license: (any LicenseGate)?
    static var chat: (any ChatEngine)?
    static var automation: (any AutomationEngine)?
    /// The `--agent` mode; nil in the community build.
    static var runAgent: (() -> Void)?

    /// Whether this build links the Pro package.
    static var isLinked: Bool { license != nil }

    /// Whether Pro is currently unlocked for the user.
    static var isUnlocked: Bool { isLinked && LicenseStatus.shared.state.unlocksPro }

    static var state: LicenseState { isLinked ? LicenseStatus.shared.state : .none }
    static var info: LicenseInfo? { LicenseStatus.shared.info }

    /// Loads the Pro implementation if this build includes it.
    ///
    /// Looked up through the Objective-C runtime rather than called directly, so the public code
    /// never references any Pro type — which is what lets it compile
    /// when the `Pro/` folder is absent.
    static func installIfAvailable() {
        guard let cls = NSClassFromString("OmitXProBootstrap") as? NSObject.Type else { return }
        cls.perform(Selector(("install")))
    }
}
