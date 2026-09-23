import Foundation

/// What the chat is allowed to do, chosen by the user on the panel.
enum ChatMode: String, CaseIterable, Identifiable, Sendable {
    /// The model only preselects items and opens the confirmation sheet — deleting still needs the user's click.
    case propose
    /// The model cleans Safe-level items by itself.
    case auto

    var id: String { rawValue }
    var label: String {
        switch self {
        case .propose: L("Đề xuất")
        case .auto: L("Tự chạy")
        }
    }
    var help: String {
        switch self {
        case .propose: L("Chat chọn sẵn các mục rồi mở bảng xác nhận để bạn duyệt.")
        case .auto: L("Chat dọn luôn các mục mức An toàn, không hỏi lại.")
        }
    }
}

/// Why the chat is not available.
enum ChatAvailability: Equatable, Sendable {
    case ready
    /// macOS older than 26 — no Foundation Models yet.
    case unsupportedOS
    /// The Mac cannot run Apple Intelligence (Intel, or a chip that is too old).
    case deviceNotEligible
    /// Supported, but the user has not turned on Apple Intelligence.
    case notEnabled
    /// The model is downloading.
    case modelNotReady
    /// The system language is not one Apple Intelligence supports.
    case unsupportedLanguage

    var isReady: Bool { self == .ready }

    var message: String {
        switch self {
        case .ready: ""
        case .unsupportedOS: L("Trợ lý cần macOS 26 trở lên.")
        case .deviceNotEligible: L("Máy này không chạy được Apple Intelligence — trợ lý cần Mac chip Apple.")
        case .notEnabled: L("Bật Apple Intelligence trong Cài đặt hệ thống để dùng trợ lý.")
        case .modelNotReady: L("macOS đang tải model về, thử lại sau ít phút.")
        case .unsupportedLanguage: L("Apple Intelligence chưa hỗ trợ ngôn ngữ hệ thống hiện tại.")
        }
    }
}

struct ChatMessage: Identifiable, Codable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant, tool, error }
    var id = UUID()
    var role: Role
    var text: String
    var date = Date()
}
