import SwiftUI

/// The assistant panel on the right. Type a request instead of ticking items one by one.
struct ChatPanel: View {
    /// Called when the assistant wants to open the confirmation sheet (Propose mode).
    let onPropose: ([CleanItem]) -> Void

    @Environment(AppState.self) private var state
    @State private var model: ChatModel?
    @State private var showHistory = false
    /// Whether the end of the conversation is within reach of the viewport's bottom edge.
    @State private var atBottom = true
    /// New content arrived while the user was scrolled up reading.
    @State private var unseen = false

    var body: some View {
        content
            .background(SidebarMaterial().ignoresSafeArea())
            .task {
                guard model == nil else { return }
                model = ChatModel(state: state, onPropose: onPropose)
#if DEBUG
                // --window-shot SHOT_CHAT: a real prompt, always in Propose mode so nothing is deleted.
                if let prompt = DebugLaunch.chatPrompt, let model {
                    DebugLaunch.chatPrompt = nil
                    model.mode = .propose
                    await model.send(prompt)
                }
#endif
            }
    }

    @ViewBuilder private var content: some View {
        if !Pro.isUnlocked {
            VStack(spacing: 0) { gateHeader; Divider(); ProGateView(feature: .chat) }
        } else if let model {
            panel(model)
        } else {
            Color.clear
        }
    }

    /// Panel title while locked — keeps the same layout as when unlocked.
    private var gateHeader: some View {
        HStack {
            Label("Trợ lý", systemImage: "sparkles").font(.headline)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func panel(_ model: ChatModel) -> some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            header(model)
            Divider()
            if model.availability.isReady {
                conversation(model)
                if model.reopened {
                    Label("Trợ lý không nhớ hội thoại này; gõ tiếp sẽ bắt đầu ngữ cảnh mới.",
                          systemImage: "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                }
                Divider()
                composer(model)
            } else {
                unavailable(model)
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            // Apple Intelligence was just turned on in System Settings — notice it right away.
            if !model.availability.isReady { model.refreshAvailability() }
        }
    }

    // MARK: Panel header

    private func header(_ model: ChatModel) -> some View {
        @Bindable var model = model
        return VStack(spacing: 6) {
            HStack {
                Label("Trợ lý", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Button {
                    model.refreshHistory()
                    showHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L("Lịch sử trò chuyện"))
                .popover(isPresented: $showHistory, arrowEdge: .bottom) { historyList(model) }
                Button {
                    model.clear()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L("Bắt đầu cuộc trò chuyện mới"))
                .disabled(model.messages.isEmpty)
            }
            if model.availability.isReady {
                Picker("", selection: $model.mode) {
                    ForEach(ChatMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help(model.mode.help)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: History

    private func historyList(_ model: ChatModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Lịch sử trò chuyện").font(.headline)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            Divider()
            if model.history.isEmpty {
                Text("Chưa có hội thoại nào.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                // With few conversations the list is exactly as tall as its content; only many scroll.
                // A ScrollView always takes all the height it is offered, so using one for two rows
                // leaves a large gap before the clear button.
                if model.history.count <= 6 {
                    historyRows(model)
                } else {
                    ScrollView { historyRows(model) }.frame(height: 320)
                }
                Divider()
                Button("Xoá toàn bộ lịch sử", role: .destructive) { model.clearHistory() }
                    .buttonStyle(.plain).foregroundStyle(.red)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .frame(width: 300)
    }

    private func historyRows(_ model: ChatModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.history) { conversation in
                Button {
                    model.open(conversation)
                    showHistory = false
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(conversation.title).lineLimit(1)
                        Text(conversation.updated.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Conversation

    /// End marker of the conversation. Scroll here rather than to the last message, so the
    /// "working…" row after the last message is always visible too.
    private static let bottom = "bottom"
    private static let scrollSpace = "chatScroll"
    /// How close to the bottom (pt) still counts as "at the bottom".
    private static let bottomSlack: CGFloat = 40

    private func conversation(_ model: ChatModel) -> some View {
        @Bindable var model = model
        return GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.messages.isEmpty { empty(model) }
                        ForEach(model.messages) { Bubble(message: $0) }
                        if model.isResponding {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Đang xử lý…").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Color.clear.frame(height: 1).id(Self.bottom)
                            .background(GeometryReader { marker in
                                Color.clear.preference(key: BottomMarkerY.self,
                                                       value: marker.frame(in: .named(Self.scrollSpace)).minY)
                            })
                    }
                    .padding(12)
                    // When shorter than the viewport, pin to the bottom next to the input — where the user is looking.
                    // Deliberately not flipping the ScrollView: on macOS that trick reverses mouse scrolling.
                    .frame(minHeight: viewport.size.height, alignment: .bottom)
                }
                .defaultScrollAnchor(.bottom)
                .coordinateSpace(name: Self.scrollSpace)
                // A lazily unloaded marker reports +infinity, i.e. far from the bottom.
                .onPreferenceChange(BottomMarkerY.self) { y in
                    atBottom = y <= viewport.size.height + Self.bottomSlack
                    if atBottom { unseen = false }
                }
                .overlay(alignment: .bottomTrailing) {
                    if unseen {
                        Button { scrollToBottom(proxy) } label: {
                            Label("Tin mới", systemImage: "arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(10)
                    }
                }
                // Opening the panel or reopening a long conversation starts at the newest message.
                .onAppear { scrollToBottom(proxy, animated: false) }
                .onChange(of: model.conversationID) {
                    unseen = false
                    scrollToBottom(proxy, animated: false)
                }
                .onChange(of: model.messages.count) { follow(proxy, model) }
                .onChange(of: model.isResponding) { follow(proxy, model) }
            }
        }
    }

    /// Follows new content only when the user is already at the bottom, or has just sent a
    /// message. Scrolled up to reread? Stay put and offer the "new messages" button instead.
    private func follow(_ proxy: ScrollViewProxy, _ model: ChatModel) {
        if atBottom || model.messages.last?.role == .user {
            scrollToBottom(proxy)
        } else {
            unseen = true
        }
    }

    /// Waits one run-loop turn for the new content to lay out before scrolling. Reopening a conversation
    /// replaces the whole message list at once: scrolling immediately finds no target and sticks at the top.
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        DispatchQueue.main.async {
            if animated {
                withAnimation { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            } else {
                proxy.scrollTo(Self.bottom, anchor: .bottom)
            }
        }
    }

    private func empty(_ model: ChatModel) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            Text(model.mode == .auto
                 ? "Chế độ Tự chạy: tôi sẽ dọn luôn các mục mức An toàn."
                 : "Nói tôi cần dọn gì, tôi chọn sẵn rồi bạn duyệt.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(model.suggestions, id: \.self) { suggestion in
                Button {
                    Task { await model.send(suggestion) }
                } label: {
                    Text(suggestion)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Input

    private func composer(_ model: ChatModel) -> some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            TextField("Dọn gì?", text: $model.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .onSubmit { Task { await model.send() } }
            Button {
                Task { await model.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isResponding)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: When unavailable

    private func unavailable(_ model: ChatModel) -> some View {
        @Bindable var model = model
        return VStack(spacing: 12) {
            Spacer()
            Image(systemName: "sparkles.slash").font(.system(size: 32)).foregroundStyle(.secondary)
            Text(model.availability.message)
                .font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
                .padding(.horizontal, 20)
            if model.availability == .notEnabled {
                Button("Mở Cài đặt hệ thống") {
                    // The "Apple Intelligence & Siri" pane (SiriPreferenceExtension), not Privacy & Security.
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Button("Kiểm tra lại") { model.refreshAvailability() }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Vertical position of the conversation's end marker inside the scroll view.
private struct BottomMarkerY: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}

private struct Bubble: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            Text(message.text)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.tint.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        case .assistant:
            Text(message.text)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .tool:
            Label(message.text, systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}
