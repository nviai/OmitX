import Foundation

/// A saved conversation.
struct ChatConversation: Codable, Identifiable, Sendable {
    var id = UUID()
    var messages: [ChatMessage] = []

    var updated: Date { messages.last?.date ?? messages.first?.date ?? .distantPast }

    /// Title taken from the user's first message — adds no strings to translate.
    var title: String {
        let first = messages.first { $0.role == .user }?.text ?? ""
        let line = first.split(whereSeparator: \.isNewline).first.map(String.init) ?? first
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 60 ? trimmed.prefix(60) + "…" : trimmed
    }
}

/// Chat history stored in `~/Library/Application Support/OmitX/chat.json`.
///
/// Chats contain project names and local paths, so the UI must offer a way to wipe
/// everything, and the number of kept conversations is capped — history must not grow forever.
enum ChatHistory {
    /// Keep the 30 most recent conversations.
    static let limit = 30

    static func load(from url: URL = OmitXPaths.chat) -> [ChatConversation] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder.omitX.decode([ChatConversation].self, from: data)
        else { return [] }
        return list
    }

    static func save(_ list: [ChatConversation], to url: URL = OmitXPaths.chat) {
        OmitXPaths.ensureSupport()
        guard let data = try? JSONEncoder.omitX.encode(list) else { return }
        try? data.write(to: url, options: .atomic)
        // Conversations are private: readable by the owner only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Replaces the conversation with the same `id` and moves it to the top. Returns the saved list.
    @discardableResult
    static func upsert(_ conversation: ChatConversation, at url: URL = OmitXPaths.chat) -> [ChatConversation] {
        guard !conversation.messages.isEmpty else { return load(from: url) }
        var list = load(from: url)
        list.removeAll { $0.id == conversation.id }
        list.insert(conversation, at: 0)
        if list.count > limit { list = Array(list.prefix(limit)) }
        save(list, to: url)
        return list
    }

    static func removeAll(at url: URL = OmitXPaths.chat) {
        try? FileManager.default.removeItem(at: url)
    }
}
