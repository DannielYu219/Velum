//
//  LLMService.swift
//  Velum
//
//  照抄 Visor 架构：Message DTO + StreamDelta + ToolCall + ModelProvider 协议 + OpenAI 兼容 Client + Keychain + Config
//

import Foundation
import Security
import os.log

// MARK: - JSONValue（JSON Schema 表达）

nonisolated enum JSONValue: Codable, Sendable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

// MARK: - ToolCall（OpenAI 格式）

nonisolated struct ToolCall: Codable, Sendable, Hashable {
    let id: String
    let type: String
    let function: FunctionCall

    enum CodingKeys: String, CodingKey { case id, type, function }

    struct FunctionCall: Codable, Sendable, Hashable {
        let name: String
        let arguments: String
    }
}

nonisolated struct ToolDefinition: Codable, Sendable, Hashable {
    let type: String
    let function: FunctionSpec

    enum CodingKeys: String, CodingKey { case type, function }

    struct FunctionSpec: Codable, Sendable, Hashable {
        let name: String
        let description: String
        let parameters: JSONValue
    }

    static func function(name: String, description: String, parameters: JSONValue) -> ToolDefinition {
        ToolDefinition(type: "function", function: FunctionSpec(name: name, description: description, parameters: parameters))
    }
}

// MARK: - Message DTO（OpenAI Chat Completions 格式）

nonisolated struct Message: Codable, Sendable, Hashable {
    let role: String
    let content: MessageContent?
    let toolCalls: [ToolCall]?
    let toolCallId: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
        case name
    }

    init(role: String, content: MessageContent? = nil, toolCalls: [ToolCall]? = nil, toolCallId: String? = nil, name: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.name = name
    }

    static func system(_ s: String) -> Message { Message(role: "system", content: .text(s)) }
    static func user(_ s: String) -> Message { Message(role: "user", content: .text(s)) }
    static func assistant(_ content: String?, toolCalls: [ToolCall]? = nil) -> Message {
        Message(role: "assistant", content: content.map { .text($0) }, toolCalls: toolCalls)
    }
    static func tool(callId: String, content: String, name: String? = nil) -> Message {
        Message(role: "tool", content: .text(content), toolCallId: callId, name: name)
    }
}

nonisolated enum MessageContent: Codable, Sendable, Hashable {
    case text(String)
    case parts([ContentPart])

    struct ContentPart: Codable, Sendable, Hashable {
        let type: String
        let text: String?
        let image_url: ImageURL?

        struct ImageURL: Codable, Sendable, Hashable { let url: String }
        enum CodingKeys: String, CodingKey { case type, text, image_url }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .text(s); return }
        if let arr = try? c.decode([ContentPart].self) { self = .parts(arr); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid content")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let s): try c.encode(s)
        case .parts(let arr): try c.encode(arr)
        }
    }

    var textValue: String? {
        switch self {
        case .text(let s): return s
        case .parts(let arr): return arr.compactMap { $0.text }.isEmpty ? nil : arr.compactMap { $0.text }.joined(separator: "\n")
        }
    }
}

// MARK: - StreamDelta

nonisolated struct StreamDelta: Sendable {
    var contentDelta: String?
    var reasoningDelta: String?
    var toolCallDeltas: [ToolCallFragment]?
    var finishReason: String?
    var usage: Usage?

    struct ToolCallFragment: Sendable {
        var index: Int
        var id: String?
        var type: String?
        var functionName: String?
        var argumentsDelta: String?
    }

    struct Usage: Sendable, Codable {
        var promptTokens: Int
        var completionTokens: Int
        var totalTokens: Int
    }
}

// MARK: - ModelProvider 协议

nonisolated protocol ModelProvider: Sendable {
    var providerName: String { get }
    func stream(messages: [Message], tools: [ToolDefinition], modelId: String) -> AsyncThrowingStream<StreamDelta, Error>
    func cancel()
}

// MARK: - ProviderError

enum ProviderError: Error, LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case invalidResponse
    case serverError(code: Int, message: String)
    case cancelled
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "未配置 API Key"
        case .invalidAPIKey: return "API Key 无效或已失效，请重新配置"
        case .invalidResponse: return "服务器响应格式无效"
        case .serverError(let code, let message): return "服务器错误（\(code)）：\(message)"
        case .cancelled: return "请求已取消"
        case .transport(let e): return "网络错误：\(e.localizedDescription)"
        }
    }
}

// MARK: - KeychainStore（金融级存储，照抄 Visor）

nonisolated enum AgentKeychain {
    private static let service = "com.lyrastudio.Velum.agent"

    static func set(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else { return }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess: return
        case errSecItemNotFound:
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(addQuery as CFDictionary, nil)
        default: break
        }
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - AgentConfig（配置管理）

@MainActor
final class AgentConfig: ObservableObject {
    static let shared = AgentConfig()

    @Published var endpoint: String {
        didSet { UserDefaults.standard.set(endpoint, forKey: "agent.endpoint") }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "agent.model") }
    }
    @Published var apiKey: String {
        didSet {
            if apiKey.isEmpty {
                AgentKeychain.delete(account: "agent_api_key")
            } else {
                try? AgentKeychain.set(apiKey, account: "agent_api_key")
            }
        }
    }
    @Published var systemPrompt: String {
        didSet { UserDefaults.standard.set(systemPrompt, forKey: "agent.systemPrompt") }
    }

    private init() {
        let defaults = UserDefaults.standard
        self.endpoint = defaults.string(forKey: "agent.endpoint") ?? "https://openrouter.ai/api/v1"
        self.model = defaults.string(forKey: "agent.model") ?? "xiaomi/mimo-v2.5"
        self.apiKey = AgentKeychain.get(account: "agent_api_key") ?? ""
        self.systemPrompt = defaults.string(forKey: "agent.systemPrompt") ?? ""
    }

    func makeProvider() -> ModelProvider? {
        // 自定义服务商（custom:: 命名空间）
        if CustomProviderRegistry.shared.isCustomModel(model) {
            return CustomProviderRegistry.shared.resolve(model)?.provider
        }
        // 默认 OpenRouter / OpenAI 兼容
        guard !apiKey.isEmpty, !endpoint.isEmpty, !model.isEmpty else { return nil }
        return OpenAICompatibleClient(baseURL: endpoint, apiKey: apiKey)
    }

    /// 实际发给 provider 的 modelId（自定义模型去掉命名空间前缀）
    var effectiveModelId: String {
        if CustomProviderRegistry.shared.isCustomModel(model) {
            return CustomProviderRegistry.shared.resolve(model)?.modelId ?? model
        }
        return model
    }

    /// 当前模型显示名（用于 UI）
    var modelDisplayName: String {
        if CustomProviderRegistry.shared.isCustomModel(model) {
            return CustomProviderRegistry.shared.displayName(for: model) ?? model
        }
        return ModelCatalog.find(model)?.displayName ?? model
    }
}

// MARK: - OpenAICompatibleClient（照抄 Visor SSE 解析）

final class OpenAICompatibleClient: ModelProvider, @unchecked Sendable {
    nonisolated let providerName = "OpenAI Compatible"
    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession
    private var currentTask: Task<Void, Never>?

    init(baseURL: String, apiKey: String, session: URLSession = .shared) {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.baseURL = URL(string: trimmed) ?? URL(string: "https://api.openai.com/v1")!
        self.apiKey = apiKey
        self.session = session
    }

    nonisolated func stream(messages: [Message], tools: [ToolDefinition], modelId: String) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let req = self.buildRequest(messages: messages, tools: tools, modelId: modelId)
            let task = Task {
                do {
                    let (bytes, response) = try await self.session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        continuation.finish(throwing: ProviderError.invalidResponse); return
                    }
                    if http.statusCode == 401 {
                        continuation.finish(throwing: ProviderError.invalidAPIKey); return
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var bodyLines: [String] = []
                        do { for try await line in bytes.lines.prefix(5) { bodyLines.append(line) } } catch {}
                        let raw = bodyLines.joined(separator: "\n")
                        var msg = "HTTP \(http.statusCode)"
                        if let data = raw.data(using: .utf8),
                           let payload = try? JSONDecoder().decode(ErrorPayload.self, from: data),
                           let err = payload.error {
                            msg = "[\(err.code ?? http.statusCode)] \(err.message ?? "未知错误")"
                        } else if !raw.isEmpty {
                            msg += ": \(String(raw.prefix(200)))"
                        }
                        continuation.finish(throwing: ProviderError.serverError(code: http.statusCode, message: msg)); return
                    }
                    try await self.parseSSE(bytes: bytes, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ProviderError.cancelled)
                } catch let e as ProviderError {
                    continuation.finish(throwing: e)
                } catch {
                    continuation.finish(throwing: ProviderError.transport(error))
                }
            }
            self.currentTask = task
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    nonisolated func cancel() { currentTask?.cancel(); currentTask = nil }

    // MARK: - Request

    nonisolated private func buildRequest(messages: [Message], tools: [ToolDefinition], modelId: String) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 0
        let body = RequestBody(model: modelId, messages: messages, stream: true,
                               tools: tools.isEmpty ? nil : tools,
                               tool_choice: tools.isEmpty ? nil : "auto")
        req.httpBody = try? JSONEncoder().encode(body)
        return req
    }

    nonisolated private struct RequestBody: Encodable {
        let model: String
        let messages: [Message]
        let stream: Bool
        let tools: [ToolDefinition]?
        let tool_choice: String?
    }

    // MARK: - SSE Parsing

    nonisolated private func parseSSE(bytes: URLSession.AsyncBytes, continuation: AsyncThrowingStream<StreamDelta, Error>.Continuation) async throws {
        for try await line in bytes.lines {
            if Task.isCancelled { throw ProviderError.cancelled }
            if line.isEmpty { continue }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { return }
            guard let data = payload.data(using: .utf8) else { continue }

            if let errPayload = try? JSONDecoder().decode(ErrorPayload.self, from: data),
               let err = errPayload.error {
                continuation.finish(throwing: ProviderError.serverError(code: err.code ?? 0, message: err.message ?? "服务器错误")); return
            }
            do {
                let chunk = try JSONDecoder().decode(SSEChunk.self, from: data)
                continuation.yield(chunk.toStreamDelta())
            } catch { continue }
        }
    }

    // MARK: - Wire Format

    nonisolated private struct ErrorPayload: Decodable {
        struct Err: Decodable { let code: Int?; let message: String? }
        let error: Err?
    }

    nonisolated private struct SSEChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let role: String?
                let content: String?
                let reasoning: String?
                let reasoning_content: String?
                let tool_calls: [ToolCallWire]?
            }
            let delta: Delta
            let finish_reason: String?
        }
        struct ToolCallWire: Decodable {
            let index: Int; let id: String?; let type: String?; let function: FunctionWire?
        }
        struct FunctionWire: Decodable { let name: String?; let arguments: String? }
        struct UsageWire: Decodable {
            let prompt_tokens: Int?; let completion_tokens: Int?; let total_tokens: Int?
        }
        let choices: [Choice]
        let usage: UsageWire?

        func toStreamDelta() -> StreamDelta {
            var d = StreamDelta()
            if let first = choices.first {
                d.contentDelta = first.delta.content
                d.reasoningDelta = first.delta.reasoning ?? first.delta.reasoning_content
                d.finishReason = first.finish_reason
                if let tcs = first.delta.tool_calls, !tcs.isEmpty {
                    d.toolCallDeltas = tcs.map { tc in
                        StreamDelta.ToolCallFragment(index: tc.index, id: tc.id, type: tc.type,
                                                     functionName: tc.function?.name,
                                                     argumentsDelta: tc.function?.arguments)
                    }
                }
            }
            if let u = usage {
                let p = u.prompt_tokens ?? 0, c = u.completion_tokens ?? 0
                d.usage = StreamDelta.Usage(promptTokens: p, completionTokens: c, totalTokens: u.total_tokens ?? (p + c))
            }
            return d
        }
    }
}
