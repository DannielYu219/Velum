//
//  AgentView.swift
//  Velum
//
//  照抄 Visor：DesignSessionView + ComposerBar + MessageBubble + MarkdownView + TypingIndicator + DesignTokens
//  适配 Velum：ObservableObject（非 @Observable）、去掉附件功能、适配窗口系统
//

import SwiftUI

// MARK: - DesignTokens（照抄 Visor）

enum AgentDesignTokens {
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }
    enum Radius {
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 20
        static let l: CGFloat = 28
    }
    enum FontSize {
        static let caption: CGFloat = 14
        static let body: CGFloat = 16
        static let bodyLarge: CGFloat = 19
        static let title: CGFloat = 24
    }
    enum Touch {
        static let standard: CGFloat = 48
        static let icon: CGFloat = 20
        static let compact: CGFloat = 44
        static let compactIcon: CGFloat = 18
    }
}

// MARK: - AgentView（照抄 Visor DesignSessionView）

struct AgentView: View {
    @StateObject private var viewModel = AgentViewModel()
    @ObservedObject private var config = AgentConfig.shared
    @State private var showSettings = false
    @State private var showDebug = false
    @State private var sidebarCollapsed: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            // 会话侧边栏
            if !sidebarCollapsed {
                SessionSidebarView(
                    selectedSessionId: $viewModel.currentSessionId,
                    isCollapsed: $sidebarCollapsed
                )
                .frame(width: 240)
                Divider().opacity(0.2)
            }

            // 主聊天区域
            VStack(spacing: 0) {
                header
                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }
                if viewModel.budgetGuard.triggeredPeriod != nil {
                    budgetWarningBanner
                }
                Divider().opacity(0.2)
                chatPanel
                ComposerBar(viewModel: viewModel)
            }
        }
        .background(Color(.systemBackground))
        .onAppear {
            Task { await viewModel.initializeSession() }
        }
        .onChange(of: viewModel.currentSessionId) { newId in
            guard let id = newId else { return }
            Task { await viewModel.loadSession(id) }
        }
        .sheet(isPresented: $showSettings) {
            AgentSettingsView()
        }
        .sheet(isPresented: $showDebug) {
            DebugView()
        }
        .alert("预算警告", isPresented: $viewModel.showBudgetAlert) {
            Button("去设置") { showSettings = true }
            Button("知道了", role: .cancel) {}
        } message: {
            Text(viewModel.budgetAlertMessage)
        }
    }

    // MARK: - Header（顶栏：模型名 + token + 设置按钮）

    private var header: some View {
        HStack(spacing: AgentDesignTokens.Spacing.s) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    sidebarCollapsed.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: AgentDesignTokens.Touch.icon, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: AgentDesignTokens.Touch.standard, height: AgentDesignTokens.Touch.standard)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(config.modelDisplayName.isEmpty ? "Agent" : config.modelDisplayName)
                    .font(.system(size: AgentDesignTokens.FontSize.title, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("in \(viewModel.sessionInputTokens)")
                    Text("·")
                    Text("out \(viewModel.sessionOutputTokens)")
                    if viewModel.sessionCostUSD > 0 {
                        Text("·")
                        Text(String(format: "$%.4f", viewModel.sessionCostUSD))
                    }
                }
                .font(.system(size: AgentDesignTokens.FontSize.caption))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Spacer()
            DebugBadgeButton(showDebug: $showDebug)
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: AgentDesignTokens.Touch.icon, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: AgentDesignTokens.Touch.standard, height: AgentDesignTokens.Touch.standard)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AgentDesignTokens.Spacing.l)
        .padding(.vertical, AgentDesignTokens.Spacing.s)
    }

    // MARK: - Budget Warning Banner（预算熔断警告）

    private var budgetWarningBanner: some View {
        HStack(spacing: AgentDesignTokens.Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("预算已熔断")
                    .font(.system(size: AgentDesignTokens.FontSize.caption, weight: .semibold))
                if let period = viewModel.budgetGuard.triggeredPeriod {
                    let pair = budgetPair(for: period)
                    Text("\(period.rawValue) $\(String(format: "%.2f", pair.spent)) / $\(String(format: "%.2f", pair.limit))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
            Button("调整预算") { showSettings = true }
                .font(.system(size: AgentDesignTokens.FontSize.caption, weight: .medium))
        }
        .padding(.horizontal, AgentDesignTokens.Spacing.l)
        .padding(.vertical, AgentDesignTokens.Spacing.s)
        .background(Color.orange.opacity(0.1))
    }

    /// 预算周期对应的 (limit, spent)
    private func budgetPair(for period: BudgetGuard.Period) -> (limit: Double, spent: Double) {
        switch period {
        case .session: return (viewModel.budgetGuard.limit.sessionUSD, viewModel.budgetGuard.sessionSpent)
        case .daily: return (viewModel.budgetGuard.limit.dailyUSD, viewModel.budgetGuard.dailySpent)
        case .monthly: return (viewModel.budgetGuard.limit.monthlyUSD, viewModel.budgetGuard.monthlySpent)
        }
    }

    // MARK: - Chat Panel

    private var chatPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AgentDesignTokens.Spacing.l) {
                    if viewModel.messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(viewModel.messages) { msg in
                            MessageBubble(message: msg)
                                .id(msg.id)
                        }
                    }
                }
                .padding(.vertical, AgentDesignTokens.Spacing.m)
            }
            .onChange(of: viewModel.messages.last?.content) { _ in
                if let last = viewModel.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: AgentDesignTokens.Spacing.s) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("输入消息开始对话")
                .font(.system(size: AgentDesignTokens.FontSize.caption))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AgentDesignTokens.Spacing.xxxl)
    }

    // MARK: - Banner

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: AgentDesignTokens.FontSize.caption))
            Spacer()
            Button {
                viewModel.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16))
            }
        }
        .padding(.horizontal, AgentDesignTokens.Spacing.l)
        .padding(.vertical, AgentDesignTokens.Spacing.s)
        .background(Color.red.opacity(0.12))
    }
}

// MARK: - ComposerBar（照抄 Visor，去掉附件功能）

struct ComposerBar: View {
    @ObservedObject var viewModel: AgentViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            TextField("输入消息…", text: $viewModel.draft, axis: .vertical)
                .font(.system(size: AgentDesignTokens.FontSize.bodyLarge))
                .lineLimit(1...5)
                .padding(.leading, 16)
                .padding(.trailing, 4)
                .padding(.vertical, 10)
                .focused($isFocused)
                .submitLabel(.send)
                .onSubmit(submit)

            Button(action: action) {
                Image(systemName: viewModel.isStreaming ? "stop.fill" : "arrow.up")
                    .font(.system(size: AgentDesignTokens.Touch.compactIcon, weight: .medium))
                    .foregroundStyle(viewModel.isStreaming ? Color.red : .primary)
                    .frame(width: AgentDesignTokens.Touch.compact, height: AgentDesignTokens.Touch.compact)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.isStreaming && viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(canSend ? 1.0 : 0.4)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
        }
        .frame(minHeight: AgentDesignTokens.Touch.compact + 12)
        .background(Color(.secondarySystemBackground), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.04), radius: 16, y: 4)
        .padding(.horizontal, AgentDesignTokens.Spacing.l)
        .padding(.bottom, AgentDesignTokens.Spacing.s)
    }

    private var canSend: Bool {
        if viewModel.isStreaming { return true }
        return !viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var action: () -> Void {
        viewModel.isStreaming ? viewModel.stop : viewModel.send
    }

    private func submit() {
        guard !viewModel.isStreaming, canSend else { return }
        viewModel.send()
    }
}

// MARK: - MessageBubble（照抄 Visor）

struct MessageBubble: View {
    let message: AgentMessage
    @State private var reasoningExpanded: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: AgentDesignTokens.Spacing.s) {
            if message.role == "user" {
                Spacer(minLength: AgentDesignTokens.Spacing.xxxl * 2)
                bubbleContent
            } else {
                bubbleContent
                Spacer(minLength: AgentDesignTokens.Spacing.xxxl * 2)
            }
        }
        .padding(.horizontal, AgentDesignTokens.Spacing.l)
    }

    @ViewBuilder
    private var bubbleContent: some View {
        VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: AgentDesignTokens.Spacing.xs) {
            if message.role == "tool" {
                toolBubble
            } else {
                if !message.reasoning.isEmpty {
                    reasoningSection
                }
                if !message.content.isEmpty || message.isStreaming {
                    contentView
                }
            }

            HStack(spacing: AgentDesignTokens.Spacing.xs) {
                if message.isStreaming {
                    TypingIndicator()
                }
            }
            .padding(.horizontal, AgentDesignTokens.Spacing.s)
        }
    }

    @ViewBuilder
    private var contentView: some View {
        let displayText = message.content.isEmpty && message.isStreaming ? " " : message.content
        if message.role == "user" {
            Text(displayText)
                .font(.system(size: AgentDesignTokens.FontSize.bodyLarge))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .padding(.horizontal, AgentDesignTokens.Spacing.l)
                .padding(.vertical, AgentDesignTokens.Spacing.m)
                .background(
                    RoundedRectangle(cornerRadius: AgentDesignTokens.Radius.m, style: .continuous)
                        .fill(Color.accentColor.opacity(0.92))
                )
        } else {
            MarkdownView(text: displayText)
                .padding(.horizontal, AgentDesignTokens.Spacing.l)
                .padding(.vertical, AgentDesignTokens.Spacing.m)
                .background(
                    RoundedRectangle(cornerRadius: AgentDesignTokens.Radius.m, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AgentDesignTokens.Radius.m, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                )
        }
    }

    private var reasoningSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    reasoningExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 11))
                    Text("思考过程")
                        .font(.system(size: AgentDesignTokens.FontSize.caption))
                    Image(systemName: reasoningExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if reasoningExpanded {
                Text(message.reasoning)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, AgentDesignTokens.Spacing.m)
                    .padding(.vertical, AgentDesignTokens.Spacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemBackground).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: AgentDesignTokens.Radius.xs, style: .continuous))
                    .padding(.top, AgentDesignTokens.Spacing.xs)
            }
        }
        .padding(.horizontal, AgentDesignTokens.Spacing.s)
    }

    private var toolBubble: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                if let name = message.name {
                    Text(name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.green)
                }
                Text(formatToolResult(message.content))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(20)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.horizontal, AgentDesignTokens.Spacing.m)
        .padding(.vertical, AgentDesignTokens.Spacing.s)
        .frame(maxWidth: 480, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AgentDesignTokens.Radius.xs, style: .continuous)
                .fill(Color.green.opacity(0.06))
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.green.opacity(0.5))
                .frame(width: 2)
        }
    }

    private func formatToolResult(_ raw: String) -> String {
        if raw.count <= 200 { return raw }
        return String(raw.prefix(200)) + "…"
    }
}

// MARK: - MarkdownView（照抄 Visor，自定义解析无第三方依赖）

struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: AgentDesignTokens.Spacing.s) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private enum Block {
        case heading(level: Int, content: String)
        case paragraph(String)
        case codeBlock(language: String?, content: String)
        case listItem(String, ordered: Bool, index: Int)
        case blockquote(String)
        case thematicBreak
        case blank
    }

    private var blocks: [Block] { parseBlocks(text) }

    private func parseBlocks(_ source: String) -> [Block] {
        var result: [Block] = []
        let lines = source.components(separatedBy: "\n")
        var i = 0
        var orderedIndex = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                result.append(.blank); orderedIndex = 0; i += 1; continue
            }
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[i]); i += 1
                }
                if i < lines.count { i += 1 }
                result.append(.codeBlock(language: lang.isEmpty ? nil : lang, content: codeLines.joined(separator: "\n")))
                orderedIndex = 0; continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                result.append(.thematicBreak); orderedIndex = 0; i += 1; continue
            }
            if let level = headingLevel(trimmed) {
                let content = trimmed.replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: .regularExpression)
                result.append(.heading(level: level, content: content)); orderedIndex = 0; i += 1; continue
            }
            if trimmed.hasPrefix(">") {
                let content = trimmed.replacingOccurrences(of: "^>\\s*", with: "", options: .regularExpression)
                result.append(.blockquote(content)); orderedIndex = 0; i += 1; continue
            }
            if let match = trimmed.range(of: "^\\d+\\.\\s", options: .regularExpression) {
                let content = String(trimmed[match.upperBound...])
                orderedIndex += 1
                result.append(.listItem(content, ordered: true, index: orderedIndex)); i += 1; continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                let content = String(trimmed.dropFirst(2))
                result.append(.listItem(content, ordered: false, index: 0)); orderedIndex = 0; i += 1; continue
            }
            result.append(.paragraph(trimmed)); orderedIndex = 0; i += 1
        }
        return result
    }

    private func headingLevel(_ line: String) -> Int? {
        var count = 0
        for ch in line { if ch == "#" { count += 1 } else { break } }
        if count > 0 && count <= 6 && line.count > count && line[line.index(line.startIndex, offsetBy: count)] == " " {
            return count
        }
        return nil
    }

    @ViewBuilder
    private func renderBlock(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let content):
            headingView(level: level, content: content)
        case .paragraph(let content):
            inlineText(content)
                .font(.system(size: AgentDesignTokens.FontSize.bodyLarge))
                .lineSpacing(4)
        case .codeBlock(_, let content):
            Text(content)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, AgentDesignTokens.Spacing.m)
                .padding(.vertical, AgentDesignTokens.Spacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemBackground).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: AgentDesignTokens.Radius.xs, style: .continuous))
        case .listItem(let content, let ordered, let index):
            HStack(alignment: .top, spacing: 6) {
                if ordered {
                    Text("\(index).").font(.system(size: AgentDesignTokens.FontSize.bodyLarge)).foregroundStyle(.secondary)
                } else {
                    Text("•").font(.system(size: AgentDesignTokens.FontSize.bodyLarge)).foregroundStyle(.secondary)
                }
                inlineText(content).font(.system(size: AgentDesignTokens.FontSize.bodyLarge)).lineSpacing(4)
            }
        case .blockquote(let content):
            HStack(alignment: .top, spacing: 8) {
                Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3)
                inlineText(content).font(.system(size: AgentDesignTokens.FontSize.bodyLarge)).foregroundStyle(.secondary).lineSpacing(4)
            }
        case .thematicBreak:
            Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 1)
        case .blank:
            Color.clear.frame(height: 4)
        }
    }

    @ViewBuilder
    private func headingView(level: Int, content: String) -> some View {
        let font: Font = {
            switch level {
            case 1: return .system(size: 26, weight: .bold)
            case 2: return .system(size: 23, weight: .bold)
            case 3: return .system(size: 21, weight: .semibold)
            case 4: return .system(size: 19, weight: .semibold)
            case 5: return .system(size: 18, weight: .semibold)
            default: return .system(size: AgentDesignTokens.FontSize.bodyLarge)
            }
        }()
        Text(inlineAttributed(content)).font(font).lineSpacing(2)
    }

    private func inlineText(_ s: String) -> some View {
        Text(inlineAttributed(s))
    }

    private func inlineAttributed(_ s: String) -> AttributedString {
        if let attr = try? AttributedString(markdown: s) { return attr }
        return AttributedString(s)
    }
}

// MARK: - TypingIndicator（照抄 Visor）

private struct TypingIndicator: View {
    @State private var phase: Int = 0
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(Color.secondary).frame(width: 5, height: 5)
                    .opacity(phase == i ? 1.0 : 0.3)
            }
        }
        .onAppear { startTimer() }
    }
    private func startTimer() {
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                phase = (phase + 1) % 3
            }
        }
    }
}
