//
//  GroupChatView.swift
//  CcCompanion
//
//  群聊 tab — 多 agent 协作频道，支持 @鸮 @opia @sonnet 等
//

import SwiftUI
import Combine

// MARK: - Models

struct GroupMember: Identifiable, Decodable {
    let id: String
    let display_name: String
    let avatar: String?
    let color: String?
    let kind: String?
    let tmux: String?
    let can_reply: Bool?
    let api_kind: String?

    var avatarText: String { (avatar ?? String(display_name.prefix(1))).isEmpty ? "?" : (avatar ?? String(display_name.prefix(1))) }
    var accentColor: Color {
        switch color ?? "" {
        case "orange":  return Color(red: 0.87, green: 0.48, blue: 0.23)
        case "blue":    return Color(red: 0.23, green: 0.48, blue: 0.87)
        case "green":   return Color(red: 0.23, green: 0.68, blue: 0.42)
        case "purple":  return Color(red: 0.54, green: 0.23, blue: 0.87)
        case "indigo":  return Color(red: 0.36, green: 0.31, blue: 0.81)
        default:        return Color.gray
        }
    }
}

struct GroupAgentStatus: Decodable {
    let state: String?
    let is_typing: Bool?
    var isOnline: Bool { state == "online" }
    var isTyping: Bool { is_typing ?? false }
}

struct GroupMessage: Identifiable {
    let id: String
    let ts: String
    let sender_id: String
    let text: String
    let mentions: [String]
    let message_type: String
}

// MARK: - Store

@MainActor
final class GroupChatStore: ObservableObject {
    @Published var messages: [GroupMessage] = []
    @Published var roster: [GroupMember] = []
    @Published var agentStatus: [String: GroupAgentStatus] = [:]
    @Published var inputText: String = ""
    @Published var sending: Bool = false

    private var lastTs: String? = nil
    private var seenIds: Set<String> = []
    private var pollTask: Task<Void, Never>?
    private var rosterTask: Task<Void, Never>?

    func start() {
        scheduleRosterRefresh()
        schedulePoll()
    }

    func stop() {
        pollTask?.cancel()
        rosterTask?.cancel()
    }

    private func scheduleRosterRefresh() {
        rosterTask?.cancel()
        rosterTask = Task {
            await fetchRoster()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                await fetchRoster()
            }
        }
    }

    private func schedulePoll() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                await poll()
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
        }
    }

    private func fetchRoster() async {
        let url = CcServerConfig.serverURL.appendingPathComponent("group/roster")
        do {
            let (data, _) = try await URLSession.shared.data(for: CcServerConfig.authenticatedRequest(url: url))
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ok = obj["ok"] as? Bool, ok else { return }
            if let rosterArr = obj["roster"] as? [[String: Any]] {
                let decoded = rosterArr.compactMap { dict -> GroupMember? in
                    guard let id = dict["id"] as? String,
                          let name = dict["display_name"] as? String else { return nil }
                    return GroupMember(
                        id: id,
                        display_name: name,
                        avatar: dict["avatar"] as? String,
                        color: dict["color"] as? String,
                        kind: dict["kind"] as? String,
                        tmux: dict["tmux"] as? String,
                        can_reply: dict["can_reply"] as? Bool,
                        api_kind: dict["api_kind"] as? String
                    )
                }
                self.roster = decoded
            }
            if let statusObj = obj["status"] as? [String: Any],
               let agents = statusObj["agents"] as? [String: [String: Any]] {
                var newStatus: [String: GroupAgentStatus] = [:]
                for (k, v) in agents {
                    newStatus[k] = GroupAgentStatus(
                        state: v["state"] as? String,
                        is_typing: v["is_typing"] as? Bool
                    )
                }
                self.agentStatus = newStatus
            }
        } catch {}
    }

    private func poll() async {
        let path = lastTs != nil
            ? "group/history?since=\(lastTs!.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&limit=50"
            : "group/history?limit=60"
        let url = CcServerConfig.serverURL.appendingPathComponent(path)
        do {
            let (data, _) = try await URLSession.shared.data(for: CcServerConfig.authenticatedRequest(url: url))
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let records = obj["records"] as? [[String: Any]] else { return }
            var newMsgs: [GroupMessage] = []
            for r in records {
                guard let id = r["id"] as? String, !seenIds.contains(id),
                      let ts = r["ts"] as? String,
                      let sender = r["sender_id"] as? String,
                      let text = r["text"] as? String else { continue }
                seenIds.insert(id)
                let mentions = (r["mentions"] as? [String]) ?? []
                let msgType = (r["message_type"] as? String) ?? "chat"
                newMsgs.append(GroupMessage(id: id, ts: ts, sender_id: sender, text: text, mentions: mentions, message_type: msgType))
                if lastTs == nil || ts > (lastTs ?? "") { lastTs = ts }
            }
            if !newMsgs.isEmpty {
                self.messages.append(contentsOf: newMsgs)
            }
            if let statusObj = obj["status"] as? [String: Any],
               let agents = statusObj["agents"] as? [String: [String: Any]] {
                var newStatus: [String: GroupAgentStatus] = [:]
                for (k, v) in agents {
                    newStatus[k] = GroupAgentStatus(
                        state: v["state"] as? String,
                        is_typing: v["is_typing"] as? Bool
                    )
                }
                self.agentStatus = newStatus
            }
        } catch {}
    }

    func send() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        defer { sending = false }
        let url = CcServerConfig.serverURL.appendingPathComponent("group/send")
        var req = CcServerConfig.authenticatedRequest(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["text": text, "sender_id": "amian"]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode == 200 {
                inputText = ""
            }
        } catch {}
    }

    func member(_ id: String) -> GroupMember? { roster.first { $0.id == id } }
}

// MARK: - Views

struct GroupChatView: View {
    @StateObject private var store = GroupChatStore()
    @FocusState private var inputFocused: Bool
    @State private var scrollProxy: ScrollViewProxy? = nil

    var body: some View {
        VStack(spacing: 0) {
            rosterBar
            Divider().overlay(Color.ccAssistant.opacity(0.1))
            messageList
            inputBar
        }
        .background(Color.ccBg)
        .navigationTitle("群聊")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.start() }
        .onDisappear { store.stop() }
        .onChange(of: store.messages.count) { _, _ in
            scrollToBottom()
        }
    }

    // MARK: Roster bar

    private var rosterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(store.roster.filter { $0.kind == "agent" }) { member in
                    let status = store.agentStatus[member.id]
                    VStack(spacing: 4) {
                        ZStack(alignment: .bottomTrailing) {
                            Circle()
                                .fill(member.accentColor.opacity(status?.isOnline == true ? 1.0 : 0.3))
                                .frame(width: 36, height: 36)
                                .overlay(
                                    Text(member.avatarText)
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.white)
                                )
                            if status?.isTyping == true {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 10, height: 10)
                                    .overlay(Circle().stroke(Color.ccBg, lineWidth: 2))
                            } else if status?.isOnline == true {
                                Circle()
                                    .fill(Color.green.opacity(0.8))
                                    .frame(width: 8, height: 8)
                                    .overlay(Circle().stroke(Color.ccBg, lineWidth: 1.5))
                            }
                        }
                        Text(member.display_name)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.ccTextDim)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color.ccCard)
    }

    // MARK: Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(store.messages) { msg in
                        GroupMessageRow(msg: msg, store: store)
                            .id(msg.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onAppear { scrollProxy = proxy }
        }
    }

    private func scrollToBottom() {
        guard let last = store.messages.last else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            scrollProxy?.scrollTo(last.id, anchor: .bottom)
        }
    }

    // MARK: Input bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("发消息… @鸮 @opia", text: $store.inputText, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.ccCard)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .focused($inputFocused)
                .onSubmit {
                    Task { await store.send() }
                }
            Button {
                Task { await store.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(store.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.ccTextDim : Color.ccAccent)
            }
            .disabled(store.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.sending)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.ccCard)
        .overlay(Divider().overlay(Color.ccAssistant.opacity(0.1)), alignment: .top)
    }
}

// MARK: - Message Row

struct GroupMessageRow: View {
    let msg: GroupMessage
    @ObservedObject var store: GroupChatStore

    private var isSelf: Bool { msg.sender_id == "amian" }
    private var member: GroupMember? { store.member(msg.sender_id) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isSelf { Spacer(minLength: 48) }
            if !isSelf { avatarView }
            VStack(alignment: isSelf ? .trailing : .leading, spacing: 3) {
                if !isSelf {
                    Text(member?.display_name ?? msg.sender_id)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ccTextDim)
                }
                bubbleView
                Text(fmtTime(msg.ts))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.ccTextDim.opacity(0.7))
            }
            if !isSelf { Spacer(minLength: 48) }
            if isSelf { avatarView }
        }
    }

    @ViewBuilder
    private var avatarView: some View {
        let color = member?.accentColor ?? Color.gray
        let text = member?.avatarText ?? String(msg.sender_id.prefix(1))
        Circle()
            .fill(color)
            .frame(width: 30, height: 30)
            .overlay(
                Text(text)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }

    @ViewBuilder
    private var bubbleView: some View {
        Text(attributedText)
            .font(.ccSerifAdaptive(size: 15))
            .foregroundStyle(isSelf ? Color.white : Color.ccText)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelf ? Color.ccAccent : Color.ccAssistant)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var attributedText: AttributedString {
        var result = AttributedString(msg.text)
        // highlight @mentions
        let pattern = try? NSRegularExpression(pattern: "@[\\w\\u4e00-\\u9fff]+")
        let nsStr = msg.text as NSString
        pattern?.enumerateMatches(in: msg.text, range: NSRange(location: 0, length: nsStr.length)) { match, _, _ in
            guard let range = match?.range,
                  let swiftRange = Range(range, in: msg.text),
                  let attrRange = Range(swiftRange, in: result) else { return }
            result[attrRange].foregroundColor = isSelf ? Color.white.opacity(0.75) : Color.ccAccent
            result[attrRange].font = .system(size: 15, weight: .semibold)
        }
        return result
    }

    private func fmtTime(_ ts: String) -> String {
        guard ts.count >= 16 else { return ts }
        return String(ts[ts.index(ts.startIndex, offsetBy: 11)..<ts.index(ts.startIndex, offsetBy: 16)])
    }
}

#Preview {
    NavigationStack { GroupChatView() }
}
