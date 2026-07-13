//
//  AgentSession.swift
//  Velum
//
//  Phase F: Session model + JSONL persistence.
//
//  用户明确要求：会话持久化不依赖 iSH fakefs，而是用 App 自己的存储。
//  因此所有 session 文件写入 App 的 Documents/agent-sessions/ 目录，
//  Session 元数据列表存入 UserDefaults（轻量、无需 Swift Data 栈）。
//
//  JSONL 格式（每行一条 message）：
//  {"id":"msg-1","role":"user","content":"列出 /etc","timestamp":"..."}
//  {"id":"msg-2","role":"assistant","content":"好的","tool_calls":[...],"timestamp":"..."}
//  {"id":"msg-3","role":"tool","content":"...","tool_call_id":"call-1","timestamp":"..."}
//
//  Spec: doc&&blueprints/50-apps/53-agent-app.md §2.6 (adapted to App-local storage)
//

import Foundation

// MARK: - Persistable Message

/// 持久化到 JSONL 的消息记录。与 UI 层的 AgentMessage 分离，
/// 避免持久化层耦合 SwiftUI 的 UUID/Identifiable。
///
/// 兼容性：旧 JSONL 文件可能含 `toolCalls` 字段（已废弃），Codable 解码时自动忽略。
/// 新代码使用 `toolCallBody`（JSON-encoded `[ToolCall]` 字符串）。
public struct PersistableMessage: Codable, Sendable, Equatable {
    public let id: String
    public let role: String          // "user" / "assistant" / "tool" / "system"
    public let content: String
    public var toolCallBody: String?   // JSON-encoded [ToolCall] 字符串
    public var toolCallId: String?
    public var name: String?
    public let timestamp: Date

    public init(id: String, role: String, content: String,
                toolCallBody: String? = nil,
                toolCallId: String? = nil,
                name: String? = nil,
                timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCallBody = toolCallBody
        self.toolCallId = toolCallId
        self.name = name
        self.timestamp = timestamp
    }
}

// MARK: - AgentSession (metadata)

public struct AgentSession: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date
    public var messageCount: Int
    public var promptTokens: Int
    public var completionTokens: Int

    public var totalTokens: Int { promptTokens + completionTokens }

    public init(id: String = Self.generateId(),
                title: String = "新会话",
                createdAt: Date = Date(),
                updatedAt: Date = Date(),
                messageCount: Int = 0,
                promptTokens: Int = 0,
                completionTokens: Int = 0) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }

    /// 生成形如 "20260713-153012-abc123" 的 ID（日期 + 短随机后缀）。
    public static func generateId() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let datePart = fmt.string(from: Date())
        let randomPart = String(UUID().uuidString.prefix(6))
        return "\(datePart)-\(randomPart)"
    }
}

// MARK: - SessionStore

/// 会话存储：管理元数据列表 + JSONL 消息文件。
/// 所有文件存放在 App Documents/agent-sessions/。
public actor SessionStore {

    public static let shared = SessionStore()

    private let fileManager = FileManager.default
    private let defaults = UserDefaults.standard
    private let metaKey = "agent.sessions.meta"

    private init() {}

    // MARK: - Directory

    /// App Documents/agent-sessions/ — 持久化根目录。
    private var sessionsDir: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = docs.appendingPathComponent("agent-sessions", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func jsonlURL(for sessionId: String) -> URL {
        sessionsDir.appendingPathComponent("\(sessionId).jsonl")
    }

    // MARK: - Metadata (UserDefaults)

    /// 读取所有会话元数据，按 updatedAt 降序返回。
    public func listSessions() -> [AgentSession] {
        guard let data = defaults.data(forKey: metaKey),
              let sessions = try? JSONDecoder().decode([AgentSession].self, from: data) else {
            return []
        }
        return sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func saveSessionsList(_ sessions: [AgentSession]) {
        if let data = try? JSONEncoder().encode(sessions) {
            defaults.set(data, forKey: metaKey)
        }
    }

    /// 新建一个空会话。
    @discardableResult
    public func createSession(title: String = "新会话") -> AgentSession {
        var session = AgentSession(title: title)
        // 确保文件存在（空 JSONL）
        let url = jsonlURL(for: session.id)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        var sessions = listSessions()
        sessions.append(session)
        saveSessionsList(sessions)
        return session
    }

    /// 更新会话元数据。
    public func updateMetadata(_ session: AgentSession) {
        var sessions = listSessions()
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx] = session
            saveSessionsList(sessions)
        }
    }

    /// 删除会话（元数据 + JSONL 文件）。
    public func deleteSession(id: String) {
        var sessions = listSessions()
        sessions.removeAll { $0.id == id }
        saveSessionsList(sessions)
        let url = jsonlURL(for: id)
        try? fileManager.removeItem(at: url)
    }

    /// 清空所有会话。
    public func deleteAllSessions() {
        let sessions = listSessions()
        for s in sessions {
            try? fileManager.removeItem(at: jsonlURL(for: s.id))
        }
        saveSessionsList([])
    }

    // MARK: - Messages (JSONL)

    /// 读取一个会话的所有消息。
    public func loadMessages(for sessionId: String) -> [PersistableMessage] {
        let url = jsonlURL(for: sessionId)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var messages: [PersistableMessage] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let lineData = line.data(using: .utf8),
               let msg = try? decoder.decode(PersistableMessage.self, from: lineData) {
                messages.append(msg)
            }
        }
        return messages
    }

    /// 追加一条消息到会话的 JSONL 文件。
    public func appendMessage(_ message: PersistableMessage, to sessionId: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let lineData = try? encoder.encode(message),
              var line = String(data: lineData, encoding: .utf8) else { return }
        line += "\n"

        let url = jsonlURL(for: sessionId)
        if let data = line.data(using: .utf8) {
            if fileManager.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }

        // 更新元数据
        var sessions = listSessions()
        if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[idx].messageCount += 1
            sessions[idx].updatedAt = Date()
            // 自动标题：首条 user 消息
            if sessions[idx].title == "新会话" && message.role == "user" {
                sessions[idx].title = Self.makeTitle(from: message.content)
            }
            saveSessionsList(sessions)
        }
    }

    /// 批量追加消息（用于流式完成后一次性写入 assistant 消息）。
    public func appendMessages(_ messages: [PersistableMessage], to sessionId: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var blob = ""
        for msg in messages {
            if let data = try? encoder.encode(msg),
               let line = String(data: data, encoding: .utf8) {
                blob += line + "\n"
            }
        }
        guard let data = blob.data(using: .utf8) else { return }
        let url = jsonlURL(for: sessionId)
        if fileManager.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }

        // 更新元数据
        var sessions = listSessions()
        if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[idx].messageCount += messages.count
            sessions[idx].updatedAt = Date()
            if sessions[idx].title == "新会话",
               let firstUser = messages.first(where: { $0.role == "user" }) {
                sessions[idx].title = Self.makeTitle(from: firstUser.content)
            }
            saveSessionsList(sessions)
        }
    }

    /// 更新 token 用量统计。
    public func addTokenUsage(sessionId: String, prompt: Int, completion: Int) {
        var sessions = listSessions()
        if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[idx].promptTokens += prompt
            sessions[idx].completionTokens += completion
            sessions[idx].updatedAt = Date()
            saveSessionsList(sessions)
        }
    }

    /// 清空某个会话的消息（保留元数据，相当于重置对话）。
    public func clearMessages(for sessionId: String) {
        let url = jsonlURL(for: sessionId)
        try? fileManager.removeItem(at: url)
        fileManager.createFile(atPath: url.path, contents: nil)

        var sessions = listSessions()
        if let idx = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[idx].messageCount = 0
            sessions[idx].promptTokens = 0
            sessions[idx].completionTokens = 0
            sessions[idx].updatedAt = Date()
            saveSessionsList(sessions)
        }
    }

    // MARK: - Title generation

    /// 从用户首条消息生成会话标题：取前 20 字符，去掉换行。
    public static func makeTitle(from text: String) -> String {
        let trimmed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 20 { return trimmed }
        return String(trimmed.prefix(20)) + "…"
    }
}
