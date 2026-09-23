import XCTest
@testable import OmitX

final class ChatHistoryTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    private func conversation(_ first: String, id: UUID = UUID()) -> ChatConversation {
        ChatConversation(id: id, messages: [
            ChatMessage(role: .user, text: first),
            ChatMessage(role: .assistant, text: "ok"),
        ])
    }

    func testRoundTripKeepsRolesAndText() {
        let saved = conversation("Dọn Xcode đi")
        ChatHistory.upsert(saved, at: url)

        let loaded = ChatHistory.load(from: url)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, saved.id)
        XCTAssertEqual(loaded[0].messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(loaded[0].messages.map(\.text), ["Dọn Xcode đi", "ok"])
    }

    func testContinuingAConversationDoesNotDuplicateIt() {
        let id = UUID()
        ChatHistory.upsert(conversation("cũ"), at: url)
        ChatHistory.upsert(conversation("lượt 1", id: id), at: url)
        var longer = conversation("lượt 1", id: id)
        longer.messages.append(ChatMessage(role: .user, text: "lượt 2"))
        let list = ChatHistory.upsert(longer, at: url)

        XCTAssertEqual(list.count, 2, "continuing overwrites instead of adding a new entry")
        XCTAssertEqual(list[0].id, id, "the conversation just used moves to the top")
        XCTAssertEqual(list[0].messages.count, 3)
    }

    func testKeepsOnlyTheNewestConversations() {
        for i in 0..<(ChatHistory.limit + 5) { ChatHistory.upsert(conversation("#\(i)"), at: url) }
        let list = ChatHistory.load(from: url)
        XCTAssertEqual(list.count, ChatHistory.limit)
        XCTAssertEqual(list.first?.title, "#\(ChatHistory.limit + 4)")
    }

    func testEmptyConversationIsNeverSaved() {
        ChatHistory.upsert(ChatConversation(), at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFileIsPrivateToTheOwner() throws {
        ChatHistory.upsert(conversation("riêng tư"), at: url)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func testRemoveAllWipesTheFile() {
        ChatHistory.upsert(conversation("xoá tôi"), at: url)
        ChatHistory.removeAll(at: url)
        XCTAssertTrue(ChatHistory.load(from: url).isEmpty)
    }

    func testTitleUsesFirstLineOfFirstUserMessage() {
        let long = String(repeating: "a", count: 80)
        XCTAssertEqual(conversation("Dòng đầu\nDòng hai").title, "Dòng đầu")
        XCTAssertEqual(conversation(long).title, String(repeating: "a", count: 60) + "…")
    }
}

/// Reopening a saved conversation hands it to the engine; the panel's "does not remember" note
/// must appear exactly when the engine could not rebuild the context.
@MainActor
final class ChatRestoreTests: XCTestCase {
    @MainActor
    private final class FakeEngine: ChatEngine {
        let canRestore: Bool
        private(set) var restored: [ChatMessage]?
        init(canRestore: Bool) { self.canRestore = canRestore }

        var availability: ChatAvailability { .ready }
        func refreshAvailability() {}
        func bind(state: AppState, onPropose: @escaping ([CleanItem]) -> Void) {}
        func setMode(_ mode: ChatMode) {}
        func respond(to text: String, note: @MainActor (String) -> Void) async throws -> String { "ok" }
        func reset() {}
        func restore(_ messages: [ChatMessage]) -> Bool {
            restored = messages
            return canRestore
        }
    }

    private let saved = ChatConversation(messages: [
        ChatMessage(role: .user, text: "How much space is free?"),
        ChatMessage(role: .assistant, text: "74 GB free."),
    ])

    private func reopen(with engine: (any ChatEngine)?) -> ChatModel {
        let previous = Pro.chat
        defer { Pro.chat = previous }
        Pro.chat = engine
        // A fresh model has no messages, so open() persists nothing to the real history file.
        let model = ChatModel(state: AppState(), onPropose: { _ in })
        model.open(saved)
        return model
    }

    func testRestoredConversationHasNoForgetfulnessNote() {
        let engine = FakeEngine(canRestore: true)
        let model = reopen(with: engine)
        XCTAssertFalse(model.reopened)
        XCTAssertEqual(engine.restored?.map(\.text), saved.messages.map(\.text), "the whole saved conversation is handed over")
        XCTAssertEqual(model.messages.count, 2)
    }

    func testNoteAppearsWhenTheEngineCannotRestore() {
        XCTAssertTrue(reopen(with: FakeEngine(canRestore: false)).reopened)
    }

    func testNoteAppearsWithoutAnEngine() {
        XCTAssertTrue(reopen(with: nil).reopened, "community build: history is read-only")
    }
}
