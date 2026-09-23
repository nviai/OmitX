import Foundation
import Observation

/// UI state of the assistant panel.
///
/// Contains no language-model logic — that lives in `Pro.chat`, which only exists in Pro builds.
@MainActor
@Observable
final class ChatModel {
    var messages: [ChatMessage] = []
    var input = ""
    var isResponding = false
    var mode: ChatMode {
        didSet {
            Pro.chat?.setMode(mode)
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
        }
    }

    static let modeKey = "chatMode"

    /// The open conversation. Saved by id so continuing it does not create a duplicate in the history.
    private(set) var conversationID = UUID()
    /// List for the history popover; re-read from disk every time it opens.
    var history: [ChatConversation] = []
    /// An old conversation was reopened but the engine could not restore its context.
    var reopened = false

    init(state: AppState, onPropose: @escaping ([CleanItem]) -> Void) {
        mode = ChatMode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .propose
        Pro.chat?.bind(state: state, onPropose: onPropose)
        Pro.chat?.setMode(mode)
    }

    /// Without the Pro package, report it as an unsupported OS.
    var availability: ChatAvailability { Pro.chat?.availability ?? .unsupportedOS }

    var suggestions: [String] {
        [L("Còn bao nhiêu dung lượng trống?"),
         L("Dọn Xcode và simulator đi"),
         L("Tìm project không đụng tới quá 90 ngày")]
    }

    func refreshAvailability() { Pro.chat?.refreshAvailability() }

    /// Starts a new conversation; the previous one is already in the history.
    func clear() {
        persist()
        conversationID = UUID()
        messages.removeAll()
        reopened = false
        Pro.chat?.reset()
    }

    // MARK: History

    func refreshHistory() { history = ChatHistory.load() }

    /// Reopens an old conversation. The engine rebuilds its context from the saved turns when it
    /// can; otherwise the conversation is read-only history and the panel says so.
    func open(_ conversation: ChatConversation) {
        persist()
        conversationID = conversation.id
        messages = conversation.messages
        reopened = !(Pro.chat?.restore(conversation.messages) ?? false)
    }

    func clearHistory() {
        ChatHistory.removeAll()
        history = []
    }

    private func persist() {
        guard !messages.isEmpty else { return }
        history = ChatHistory.upsert(ChatConversation(id: conversationID, messages: messages))
    }

    func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding else { return }
        input = ""
        await send(text)
    }

    func send(_ text: String) async {
        guard !isResponding else { return }
        reopened = false
        messages.append(ChatMessage(role: .user, text: text))
        guard let engine = Pro.chat else {
            messages.append(ChatMessage(role: .error, text: ChatAvailability.unsupportedOS.message))
            return
        }
        isResponding = true
        defer { isResponding = false }
        do {
            let reply = try await engine.respond(to: text) { [weak self] note in
                self?.messages.append(ChatMessage(role: .tool, text: note))
            }
            messages.append(ChatMessage(role: .assistant, text: reply))
        } catch {
            messages.append(ChatMessage(role: .error, text: error.localizedDescription))
        }
        persist()
    }
}
