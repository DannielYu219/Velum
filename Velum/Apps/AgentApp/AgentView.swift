//
//  AgentView.swift
//  Velum
//
//  Phase 5.2 + 5.3: Agent App 对话 UI + MCP 客户端
//
//  上下结构：消息流（ScrollView + LazyVStack）+ 输入框（TextEditor + 发送按钮）
//  用户输入 → 转发给 LLM → LLM 返回 tool_call → 通过 MCP 协议调用 → 结果回显
//

import SwiftUI

// MARK: - Message Model

struct AgentMessage: Identifiable, Hashable {
    let id = UUID()
    let role: Role
    var content: String
    var toolCalls: [ToolCallRecord]
    let timestamp: Date

    enum Role: String {
        case user
        case assistant
        case tool
    }

    init(role: Role, content: String, toolCalls: [ToolCallRecord] = []) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.timestamp = Date()
    }
}

struct ToolCallRecord: Hashable {
    let toolName: String
    let arguments: String
    var result: String?
    var isError: Bool = false
}

// MARK: - AgentViewModel

@MainActor
final class AgentViewModel: ObservableObject {

    @Published var messages: [AgentMessage] = []
    @Published var inputText: String = ""
    @Published var isProcessing: Bool = false
    @Published var availableTools: [MCPTool] = []

    // 连接到本机 MCP Server 的客户端
    private let client = MCPClient(endpoint: "127.0.0.1", port: 8765)

    init() {
        // 欢迎消息
        messages.append(AgentMessage(
            role: .assistant,
            content: "你好！我是 Velum Agent。我可以帮你执行 shell 命令、管理文件、启动应用等。试试问我「列出 /etc 下的文件」或「执行 uname -a」。"
        ))
    }

    func loadTools() async {
        do {
            let tools = try await client.listTools()
            availableTools = tools
        } catch {
            print("[Agent] 加载工具列表失败: \(error)")
        }
    }

    func send() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isProcessing else { return }

        // 添加用户消息
        messages.append(AgentMessage(role: .user, content: text))
        inputText = ""
        isProcessing = true

        // 添加占位 assistant 消息（流式更新）
        let assistantIdx = messages.count
        messages.append(AgentMessage(role: .assistant, content: "思考中…"))

        do {
            // 调用 mock LLM（Step 5.3 用真实 LLM 替换）
            let response = try await MockLLM.respond(
                to: text,
                availableTools: availableTools.map { $0.name }
            )

            // 如果 LLM 决定调 tool
            if let toolCall = response.toolCall {
                let argsJson = toolCall.arguments
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key): \($0.value)" }
                    .joined(separator: ", ")

                var record = ToolCallRecord(
                    toolName: toolCall.name,
                    arguments: argsJson
                )

                // 通过 MCP 客户端调用 tool
                do {
                    let result = try await client.callTool(name: toolCall.name, args: toolCall.arguments)
                    record.result = result.content.first?.text ?? "(空)"
                    record.isError = result.isError
                } catch {
                    record.result = "调用失败: \(error.localizedDescription)"
                    record.isError = true
                }

                messages[assistantIdx].content = response.text
                messages[assistantIdx].toolCalls = [record]

                // 添加 tool 结果消息
                messages.append(AgentMessage(
                    role: .tool,
                    content: record.result ?? "(无输出)"
                ))

                // 让 LLM 看到结果后再总结
                let summary = try await MockLLM.summarize(
                    userQuery: text,
                    toolName: toolCall.name,
                    toolResult: record.result ?? ""
                )
                messages.append(AgentMessage(role: .assistant, content: summary))
            } else {
                // 纯文本回复
                messages[assistantIdx].content = response.text
            }
        } catch {
            messages[assistantIdx].content = "出错: \(error.localizedDescription)"
        }

        isProcessing = false
    }
}

// MARK: - AgentView

struct AgentView: View {
    @StateObject private var vm = AgentViewModel()

    var body: some View {
        VStack(spacing: 0) {
            messageList
            inputBar
        }
        .background(Color.clear)
        .task {
            await vm.loadTools()
        }
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(vm.messages) { msg in
                        MessageBubble(message: msg)
                            .id(msg.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: vm.messages.count) { _ in
                if let last = vm.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextEditor(text: $vm.inputText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .frame(minHeight: 28, maxHeight: 80)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            Button {
                Task { await vm.send() }
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(
                        vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.gray.opacity(0.4)
                            : Color.accentColor
                    )
                    .clipShape(Circle())
            }
            .disabled(vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isProcessing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.2))
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let message: AgentMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                // 显示 tool 调用记录
                ForEach(message.toolCalls.indices, id: \.self) { i in
                    ToolCallView(record: message.toolCalls[i])
                }
            }
            if message.role != .user { Spacer(minLength: 40) }
        }
    }

    private var bubbleBackground: Color {
        switch message.role {
        case .user:      return Color.accentColor.opacity(0.2)
        case .assistant: return Color.white.opacity(0.08)
        case .tool:      return Color.green.opacity(0.1)
        }
    }
}

private struct ToolCallView: View {
    let record: ToolCallRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: record.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(record.isError ? .orange : .green)
                    .font(.caption)
                Text(record.toolName)
                    .font(.caption.monospaced())
                    .fontWeight(.semibold)
            }
            Text(record.arguments)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if let result = record.result {
                Text(result)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
                    .padding(6)
                    .background(Color.black.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
