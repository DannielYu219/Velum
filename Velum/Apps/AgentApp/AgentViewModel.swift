//
//  AgentViewModel.swift
//  Velum
//
//  照抄 Visor 架构：AgentMessage + AgentTools(ISHBridge) + AgentRuntime + AgentViewModel
//  降级 @Observable → ObservableObject 保持 iOS 16+ 兼容
//

import Foundation
import SwiftUI

// MARK: - AgentMessage（UI 层消息模型，照抄 Visor ChatMessage）

struct AgentMessage: Identifiable, Hashable {
    let id: UUID
    let role: String                  // "user" / "assistant" / "tool"
    var content: String
    var reasoning: String = ""
    var toolCallBody: String? = nil
    var toolCallId: String? = nil
    var name: String? = nil
    var isStreaming: Bool = false
    var costUSD: Double = 0
    var createdAt: Date

    init(id: UUID = UUID(), role: String, content: String, reasoning: String = "",
         toolCallBody: String? = nil, toolCallId: String? = nil, name: String? = nil,
         isStreaming: Bool = false, costUSD: Double = 0, createdAt: Date = Date()) {
        self.id = id; self.role = role; self.content = content; self.reasoning = reasoning
        self.toolCallBody = toolCallBody; self.toolCallId = toolCallId; self.name = name
        self.isStreaming = isStreaming; self.costUSD = costUSD; self.createdAt = createdAt
    }
}

// MARK: - AgentTools（基于 ISHBridge 的工具集，照抄 Visor FileTools 格式）

nonisolated struct AgentTools {

    /// 全部工具定义（发给模型）
    static var all: [ToolDefinition] {
        [shell, listDir, readFile, writeFile]
    }

    static var shell: ToolDefinition {
        ToolDefinition.function(
            name: "shell",
            description: "在 iSH (Alpine Linux aarch64) 中执行 shell 命令。可以运行任意命令：ls, cat, grep, apk, git, python 等。",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "command": .object([
                        "type": .string("string"),
                        "description": .string("要执行的 shell 命令")
                    ])
                ]),
                "required": .array([.string("command")])
            ])
        )
    }

    static var listDir: ToolDefinition {
        ToolDefinition.function(
            name: "list_dir",
            description: "列出指定目录下的文件和子目录",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("目录路径，如 / 或 /root")
                    ])
                ]),
                "required": .array([.string("path")])
            ])
        )
    }

    static var readFile: ToolDefinition {
        ToolDefinition.function(
            name: "read_file",
            description: "读取文本文件内容",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("文件路径")
                    ])
                ]),
                "required": .array([.string("path")])
            ])
        )
    }

    static var writeFile: ToolDefinition {
        ToolDefinition.function(
            name: "write_file",
            description: "写入文本文件（覆盖已存在文件）",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("文件路径")
                    ]),
                    "content": .object([
                        "type": .string("string"),
                        "description": .string("文件内容")
                    ])
                ]),
                "required": .array([.string("path"), .string("content")])
            ])
        )
    }

    // MARK: - 执行

    /// 执行工具调用，返回 JSON 字符串
    static func execute(name: String, argumentsJSON: String) async -> String {
        let args = (try? JSONSerialization.jsonObject(with: argumentsJSON.data(using: .utf8) ?? Data()) as? [String: Any]) ?? [:]
        let bridge = ISHBridge.shared

        switch name {
        case "shell":
            let command = args["command"] as? String ?? ""
            guard !command.isEmpty else { return errorJSON("invalid_args", "command 不能为空") }
            do {
                let result = try await bridge.execute(command)
                return successJSON([
                    "ok": result.isSuccess,
                    "exit_code": result.exitCode,
                    "output": result.output,
                    "stderr": result.errorOutput,
                    "command": command
                ])
            } catch {
                return errorJSON("exec_error", "\(error)")
            }

        case "list_dir":
            let path = args["path"] as? String ?? "/"
            do {
                let entries = try await bridge.listDir(path)
                let arr = entries.map { e -> [String: Any] in
                    ["name": e.name, "size": e.size, "is_dir": e.isDirectory, "perms": e.permissionString]
                }
                return successJSON(["ok": true, "path": path, "entries": arr])
            } catch {
                return errorJSON("exec_error", "\(error)")
            }

        case "read_file":
            let path = args["path"] as? String ?? ""
            guard !path.isEmpty else { return errorJSON("invalid_args", "path 不能为空") }
            do {
                let text = try await bridge.readTextFile(path)
                return successJSON(["ok": true, "path": path, "content": text])
            } catch {
                return errorJSON("exec_error", "\(error)")
            }

        case "write_file":
            let path = args["path"] as? String ?? ""
            let content = args["content"] as? String ?? ""
            guard !path.isEmpty else { return errorJSON("invalid_args", "path 不能为空") }
            do {
                let written = try await bridge.writeTextFile(path, text: content)
                return successJSON(["ok": true, "path": path, "bytes": written])
            } catch {
                return errorJSON("exec_error", "\(error)")
            }

        default:
            return errorJSON("unknown_tool", "未知工具: \(name)")
        }
    }

    // MARK: - JSON 工具

    private static func successJSON(_ obj: [String: Any]) -> String {
        var withOk = obj; withOk["ok"] = true
        guard let data = try? JSONSerialization.data(withJSONObject: withOk, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{\"ok\":true}" }
        return s
    }

    private static func errorJSON(_ code: String, _ message: String) -> String {
        let obj: [String: Any] = ["ok": false, "error": code, "message": message]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{\"ok\":false}" }
        return s
    }
}

// MARK: - AgentRuntime（照抄 Visor，去掉 SkillRouter/FileSystemStore）

final class AgentRuntime: @unchecked Sendable {
    private let maxToolRounds = 10
    private var currentTask: Task<Void, Never>?
    private var currentProvider: ModelProvider?

    enum Event: Sendable {
        case reasoningDelta(String)
        case textDelta(String)
        case toolCallStarted(name: String)
        case assistantMessage(Message)
        case toolMessage(Message)
        case usage(prompt: Int, completion: Int)
        case error(String)
        case completed
    }

    func run(userInput: String, history: [Message], provider: ModelProvider, modelId: String) -> AsyncStream<Event> {
        currentTask?.cancel()
        currentProvider?.cancel()
        currentProvider = provider

        let (stream, continuation) = AsyncStream<Event>.makeStream()

        currentTask = Task.detached {
            defer { continuation.finish() }
            await self.runInternal(userInput: userInput, history: history, provider: provider,
                                   modelId: modelId, continuation: continuation)
        }
        continuation.onTermination = { @Sendable _ in self.currentTask?.cancel() }
        return stream
    }

    func cancel() {
        currentTask?.cancel()
        currentProvider?.cancel()
        currentProvider = nil
    }

    // MARK: - Core Loop

    private func runInternal(userInput: String, history: [Message], provider: ModelProvider,
                             modelId: String, continuation: AsyncStream<Event>.Continuation) async {
        var systemPrompt = """
        你是 Velum Agent，运行在 iOS 上的 iSH Linux 桌面环境中。
        你可以通过工具调用直接操作 iSH 内的文件系统、进程和 shell。
        所有命令在 Alpine Linux (aarch64) 上执行。

        工作方式：
        - 用户提出需求 → 你判断是否需要调用工具 → 调用工具获取结果 → 基于结果回答
        - 可以连续调用多个工具完成复杂任务
        - 用中文回答，除非用户用英文提问
        - 回答简洁直接，不要客套
        """
        let customPrompt = await MainActor.run { AgentConfig.shared.systemPrompt }
        if !customPrompt.isEmpty {
            systemPrompt += "\n\n" + customPrompt
        }

        // 注入已安装 Skill 的能力指令（来自 Skill 商店）
        if let skillPrompt = await MainActor.run { SkillRegistry.shared.composedSystemPrompt() } {
            systemPrompt += "\n\n" + skillPrompt
        }

        var messages: [Message] = [.system(systemPrompt)]
        messages.append(contentsOf: history)
        messages.append(.user(userInput))

        for round in 1...maxToolRounds {
            if Task.isCancelled { return }

            let stream = provider.stream(messages: messages, tools: AgentTools.all, modelId: modelId)

            var textAccum = ""
            var toolFragments: [Int: ToolCallBuilder] = [:]
            var finishReason: String?
            var lastUsage: StreamDelta.Usage?
            var toolCallNotified: Set<Int> = []
            var deltaCount = 0

            let watchdog = Task {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                if !Task.isCancelled {
                    continuation.yield(.error("120 秒无响应，可能卡死"))
                }
            }

            do {
                for try await delta in stream {
                    watchdog.cancel()
                    if Task.isCancelled { return }
                    deltaCount += 1

                    if let r = delta.reasoningDelta { continuation.yield(.reasoningDelta(r)) }
                    if let text = delta.contentDelta {
                        textAccum += text
                        continuation.yield(.textDelta(text))
                    }
                    if let tcds = delta.toolCallDeltas {
                        for tcd in tcds {
                            var b = toolFragments[tcd.index] ?? ToolCallBuilder()
                            if let id = tcd.id { b.id = id }
                            if let type = tcd.type { b.type = type }
                            if let name = tcd.functionName { b.name += name }
                            if let args = tcd.argumentsDelta { b.arguments += args }
                            toolFragments[tcd.index] = b

                            if !toolCallNotified.contains(tcd.index) && !b.name.isEmpty {
                                toolCallNotified.insert(tcd.index)
                                continuation.yield(.toolCallStarted(name: b.name))
                            }
                        }
                    }
                    if let fr = delta.finishReason { finishReason = fr }
                    if let u = delta.usage { lastUsage = u }
                }
            } catch {
                watchdog.cancel()
                continuation.yield(.error("流式错误：\(error.localizedDescription)"))
                return
            }
            watchdog.cancel()

            if let u = lastUsage {
                continuation.yield(.usage(prompt: u.promptTokens, completion: u.completionTokens))
            }

            if finishReason == "error" {
                continuation.yield(.error("模型返回错误"))
                return
            }

            let toolCalls: [ToolCall] = toolFragments.sorted { $0.key < $1.key }.compactMap { $0.value.build() }

            if toolCalls.isEmpty {
                break
            }

            // 验证 + 修复 arguments JSON
            var validToolCalls: [ToolCall] = []
            for tc in toolCalls {
                if isValidJSON(tc.function.arguments) {
                    validToolCalls.append(tc)
                } else {
                    let repaired = repairArgumentsJSON(tc.function.arguments)
                    if isValidJSON(repaired) {
                        validToolCalls.append(ToolCall(id: tc.id, type: tc.type,
                            function: .init(name: tc.function.name, arguments: repaired)))
                    }
                }
            }

            if validToolCalls.isEmpty { break }

            let assistantMsg = Message.assistant(textAccum.isEmpty ? nil : textAccum, toolCalls: validToolCalls)
            messages.append(assistantMsg)
            continuation.yield(.assistantMessage(assistantMsg))

            // 执行工具
            for tc in validToolCalls {
                let result = await AgentTools.execute(name: tc.function.name, argumentsJSON: tc.function.arguments)
                let toolMsg = Message.tool(callId: tc.id, content: result, name: tc.function.name)
                messages.append(toolMsg)
                continuation.yield(.toolMessage(toolMsg))
            }
        }

        continuation.yield(.completed)
    }

    // MARK: - JSON 工具

    private func isValidJSON(_ s: String) -> Bool {
        guard let data = s.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private func repairArgumentsJSON(_ s: String) -> String {
        var repaired = s
        guard repaired.hasPrefix("{") else { return repaired }
        var inString = false
        var escape = false
        var braceDepth = 0
        var bracketDepth = 0
        for ch in repaired {
            if escape { escape = false; continue }
            if ch == "\\" && inString { escape = true; continue }
            if ch == "\"" { inString.toggle(); continue }
            if inString { continue }
            switch ch {
            case "{": braceDepth += 1
            case "}": braceDepth -= 1
            case "[": bracketDepth += 1
            case "]": bracketDepth -= 1
            default: break
            }
        }
        if inString { repaired += "\"" }
        for _ in 0..<max(0, bracketDepth) { repaired += "]" }
        for _ in 0..<max(0, braceDepth) { repaired += "}" }
        return repaired
    }

    private struct ToolCallBuilder {
        var id: String = ""
        var type: String = ""
        var name: String = ""
        var arguments: String = ""
        func build() -> ToolCall? {
            guard !name.isEmpty else { return nil }
            let finalId = id.isEmpty ? "call_\(UUID().uuidString.prefix(8))" : id
            return ToolCall(id: finalId, type: type.isEmpty ? "function" : type,
                            function: .init(name: name, arguments: arguments))
        }
    }
}

// MARK: - AgentViewModel（照抄 Visor ChatViewModel，降级为 ObservableObject）

@MainActor
final class AgentViewModel: ObservableObject {

    @Published var messages: [AgentMessage] = []
    @Published var draft: String = ""
    @Published var isStreaming: Bool = false
    @Published var errorMessage: String?
    @Published var sessionInputTokens: Int = 0
    @Published var sessionOutputTokens: Int = 0
    @Published var sessionCostUSD: Double = 0

    /// 预算熔断（金融级安全）— 使用单例共享
    @Published var budgetGuard = BudgetGuard.shared
    /// 预算超限提示（一次性弹窗）
    @Published var showBudgetAlert: Bool = false
    @Published var budgetAlertMessage: String = ""

    private let runtime = AgentRuntime()
    private var consumeTask: Task<Void, Never>?
    private var currentAssistantId: UUID?
    @Published var currentSessionId: String?

    init() {}

    // MARK: - Session

    /// 初始化：选择最近的会话，或创建新会话
    func initializeSession() async {
        let sessions = await SessionStore.shared.listSessions()
        if let latest = sessions.first {
            currentSessionId = latest.id
            await loadSession(latest.id)
        } else {
            let new = await SessionStore.shared.createSession()
            currentSessionId = new.id
            await loadSession(new.id)
        }
    }

    func loadSession(_ id: String) async {
        currentSessionId = id
        let persisted = await SessionStore.shared.loadMessages(for: id)
        if persisted.isEmpty {
            messages = [AgentMessage(role: "assistant", content: "你好！我是 Velum Agent，可以帮你执行 shell 命令、管理文件等。有什么可以帮你的？")]
        } else {
            messages = persisted.map { p in
                AgentMessage(id: UUID(uuidString: p.id) ?? UUID(), role: p.role, content: p.content,
                             toolCallBody: p.toolCallBody, toolCallId: p.toolCallId, name: p.name)
            }
        }
    }

    // MARK: - Send

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        guard let sessionId = currentSessionId else { return }

        // 预算熔断检查（金融级安全：预估 $0.05 单次调用）
        let estimate: Double = 0.05
        if !budgetGuard.checkAndCharge(estimatedUSD: estimate) {
            let period = budgetGuard.triggeredPeriod ?? .session
            let msg: String
            switch period {
            case .session:
                msg = "已达会话预算上限 $\(String(format: "%.2f", budgetGuard.limit.sessionUSD))"
            case .daily:
                msg = "已达日预算上限 $\(String(format: "%.2f", budgetGuard.limit.dailyUSD))"
            case .monthly:
                msg = "已达月预算上限 $\(String(format: "%.2f", budgetGuard.limit.monthlyUSD))"
            }
            budgetAlertMessage = msg
            showBudgetAlert = true
            DebugBus.shared.error("预算熔断：\(msg)")
            return
        }

        let userMsg = AgentMessage(role: "user", content: text)
        messages.append(userMsg)
        Task { await SessionStore.shared.appendMessage(
            PersistableMessage(id: userMsg.id.uuidString, role: "user", content: text), to: sessionId) }
        draft = ""
        errorMessage = nil
        DebugBus.shared.cli("发送消息：\(text.prefix(100))")

        let assistantId = UUID()
        messages.append(AgentMessage(id: assistantId, role: "assistant", content: "", isStreaming: true))
        isStreaming = true
        currentAssistantId = assistantId

        // 构建 history（排除当前 user 和 assistant 占位）
        // 关键 OpenAI API 规则：
        // 1. assistant 消息必须有 content 或 tool_calls（非空）
        // 2. assistant 消息带 tool_calls 时，后面必须紧跟 tool 消息响应每个 tool_call_id
        // 3. tool 消息必须有对应的 tool_call_id 且前面有带 tool_calls 的 assistant 消息
        // 违反任何一条都会返回 400
        let rawHistory = messages.filter { $0.id != assistantId && $0.id != userMsg.id }.compactMap { msg -> Message? in
            if msg.content.isEmpty && msg.toolCallBody == nil && msg.toolCallId == nil { return nil }
            if msg.role == "tool" && msg.toolCallId == nil { return nil }

            var toolCalls: [ToolCall]? = nil
            if let body = msg.toolCallBody,
               let data = body.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([ToolCall].self, from: data),
               !decoded.isEmpty {
                toolCalls = decoded
            }

            // assistant 消息既没 content 也没 tool_calls → 跳过（避免 400 错误）
            if msg.role == "assistant" && msg.content.isEmpty && toolCalls == nil { return nil }

            // assistant 消息带 tool_calls 时，content 可以为空字符串但不能为 nil
            let content: MessageContent?
            if msg.role == "assistant" {
                content = .text(msg.content)
            } else {
                content = msg.content.isEmpty ? nil : .text(msg.content)
            }
            return Message(role: msg.role, content: content,
                          toolCalls: toolCalls, toolCallId: msg.toolCallId, name: msg.name)
        }

        // 严格配对检查：确保每个 tool_calls 都有完整的 tool 消息响应
        // 场景：中断后 assistant 有 2 个 tool_calls 但只有 1 个 tool 消息 → 移除 tool_calls 降级
        var history: [Message] = []
        var idx = 0
        while idx < rawHistory.count {
            let msg = rawHistory[idx]

            if msg.role == "assistant", let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                // 收集所有期望的 tool_call_id
                let expectedIds = Set(toolCalls.map { $0.id })

                // 向后扫描连续的 tool 消息
                var toolMessages: [Message] = []
                var j = idx + 1
                while j < rawHistory.count && rawHistory[j].role == "tool" {
                    toolMessages.append(rawHistory[j])
                    j += 1
                }

                // 检查每个 tool_call_id 是否都有对应 tool 消息
                let foundIds = Set(toolMessages.compactMap { $0.toolCallId })
                let allResponded = expectedIds == foundIds && toolMessages.count == expectedIds.count

                if allResponded {
                    // 完全配对：assistant + 所有 tool 消息
                    history.append(msg)
                    history.append(contentsOf: toolMessages)
                    idx = j
                } else {
                    // 配对不完整：移除 tool_calls 降级为普通 assistant 消息
                    // 如果 content 为空则整条消息跳过（避免 400）
                    if case .text(let text) = msg.content, !text.isEmpty {
                        history.append(Message(role: "assistant", content: msg.content, toolCalls: nil))
                    }
                    // 跳过这条 assistant 和后续孤立的 tool 消息
                    idx = j
                }
            } else if msg.role == "tool" {
                // 孤立的 tool 消息（前面没有配对的 assistant tool_calls）：跳过
                idx += 1
            } else {
                history.append(msg)
                idx += 1
            }
        }

        guard let provider = AgentConfig.shared.makeProvider() else {
            errorMessage = "请先在设置中配置 Endpoint、Model 和 API Key，或添加自定义服务商"
            finishStreaming()
            return
        }

        let modelId = AgentConfig.shared.effectiveModelId
        let stream = runtime.run(userInput: text, history: history, provider: provider, modelId: modelId)

        consumeTask?.cancel()
        consumeTask = Task.detached { [weak self] in
            for await event in stream {
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self = self else { return }
                    self.handleEvent(event)
                }
            }
            await MainActor.run {
                guard let self = self else { return }
                self.finishStreaming()
            }
        }
    }

    func stop() {
        consumeTask?.cancel()
        runtime.cancel()
        finishStreaming()
    }

    // MARK: - Event Handling

    private func handleEvent(_ event: AgentRuntime.Event) {
        switch event {
        case .reasoningDelta(let text):
            guard let id = currentAssistantId,
                  let idx = messages.firstIndex(where: { $0.id == id }) else { return }
            messages[idx].reasoning.append(text)

        case .textDelta(let text):
            guard let id = currentAssistantId,
                  let idx = messages.firstIndex(where: { $0.id == id }) else { return }
            messages[idx].content.append(text)

        case .toolCallStarted(let name):
            // 不再输出"🔧 正在调用工具"提示消息，只关闭 streaming 占位
            if let id = currentAssistantId,
               let idx = messages.firstIndex(where: { $0.id == id }) {
                messages[idx].isStreaming = false
                if messages[idx].content.isEmpty && messages[idx].reasoning.isEmpty {
                    messages.remove(at: idx)
                }
            }
            DebugBus.shared.cli("⚙ 工具调用开始：\(name)")

        case .assistantMessage(let msg):
            if let tcs = msg.toolCalls, !tcs.isEmpty {
                // 关闭 streaming 占位
                if let id = currentAssistantId,
                   let idx = messages.firstIndex(where: { $0.id == id }) {
                    messages[idx].isStreaming = false
                    if messages[idx].content.isEmpty && messages[idx].reasoning.isEmpty {
                        messages.remove(at: idx)
                    }
                }
                // 保留 toolCallBody 用于历史重建，但 content 为空不在 UI 显示
                let body: String = {
                    if let data = try? JSONEncoder().encode(tcs),
                       let s = String(data: data, encoding: .utf8) { return s }
                    return "[]"
                }()
                let toolMsg = AgentMessage(role: "assistant", content: "", toolCallBody: body)
                messages.append(toolMsg)
                if let sid = currentSessionId {
                    Task { await SessionStore.shared.appendMessage(
                        PersistableMessage(id: toolMsg.id.uuidString, role: "assistant",
                                          content: "", toolCallBody: body), to: sid) }
                }
                let names = tcs.map { $0.function.name }.joined(separator: ", ")
                DebugBus.shared.cli("⚙ 工具调用：\(names)")
            }

        case .toolMessage(let msg):
            if let id = currentAssistantId,
               let idx = messages.firstIndex(where: { $0.id == id }) {
                messages[idx].isStreaming = false
            }
            let toolMsg = AgentMessage(role: "tool", content: msg.content?.textValue ?? "",
                                       toolCallId: msg.toolCallId, name: msg.name)
            messages.append(toolMsg)
            if let sid = currentSessionId {
                Task { await SessionStore.shared.appendMessage(
                    PersistableMessage(id: toolMsg.id.uuidString, role: "tool",
                                      content: toolMsg.content, toolCallId: msg.toolCallId, name: msg.name), to: sid) }
            }
            // Debug：工具调用详情（含 args + result）
            var argsForDebug = ""
            if let tid = msg.toolCallId,
               let lastAssistant = messages.last(where: { $0.role == "assistant" && $0.toolCallBody != nil }),
               let data = lastAssistant.toolCallBody?.data(using: .utf8),
               let calls = try? JSONDecoder().decode([ToolCall].self, from: data) {
                if let match = calls.first(where: { $0.id == tid }) {
                    argsForDebug = match.function.arguments
                }
            }
            DebugBus.shared.tool(msg.name ?? "?", args: argsForDebug, result: msg.content?.textValue ?? "")
            let placeholder = AgentMessage(role: "assistant", content: "", isStreaming: true)
            messages.append(placeholder)
            currentAssistantId = placeholder.id

        case .usage(let prompt, let completion):
            sessionInputTokens += prompt
            sessionOutputTokens += completion
            // 照抄 Visor：用 ModelPricingTable 计算单次成本并累加
            let modelId = AgentConfig.shared.effectiveModelId
            let cost = ModelPricingTable.shared.costUSD(
                modelId: modelId, inputTokens: prompt, outputTokens: completion
            )
            sessionCostUSD += cost
            // 写入当前 streaming 的 assistant 消息
            if let id = currentAssistantId,
               let idx = messages.firstIndex(where: { $0.id == id }) {
                messages[idx].costUSD += cost
            }
            // 实际结算预算（校正预估差额）
            budgetGuard.settle(actualUSD: cost, estimatedUSD: 0.05)
            DebugBus.shared.token(modelId, prompt: prompt, completion: completion, costUSD: cost)

        case .error(let msg):
            errorMessage = msg
            DebugBus.shared.error(msg)

        case .completed:
            break
        }
    }

    private func finishStreaming() {
        isStreaming = false
        if let id = currentAssistantId,
           let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].isStreaming = false
            if messages[idx].content.isEmpty && messages[idx].reasoning.isEmpty {
                messages.remove(at: idx)
            } else if let sid = currentSessionId {
                let content = messages[idx].content
                let toolCallBody = messages[idx].toolCallBody
                Task { await SessionStore.shared.appendMessage(
                    PersistableMessage(id: id.uuidString, role: "assistant", content: content,
                                      toolCallBody: toolCallBody), to: sid) }
            }
        }
        currentAssistantId = nil
    }
}
