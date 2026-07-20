//
//  DebugBus.swift
//  Velum
//
//  照抄 Visor DebugEvent + DebugBus：全局调试事件总线
//  环形缓冲 1000 条，按 Kind 分类（cli/token/error/sse/tool）
//

import Foundation
import SwiftUI
import Combine

/// Debug 事件统一模型
struct DebugEvent: Identifiable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    let kind: Kind
    let level: Level
    let title: String
    let detail: String

    enum Kind: String, Sendable, CaseIterable {
        case cli       // 终端 / CLI 命令
        case token     // Token / 费用
        case error     // 错误
        case sse       // 流式数据（network）
        case tool      // 工具调用
    }

    enum Level: String, Sendable {
        case info
        case warn
        case error
        case success
    }

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: Kind,
        level: Level = .info,
        title: String,
        detail: String = ""
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.level = level
        self.title = title
        self.detail = detail
    }

    var iconName: String {
        switch kind {
        case .cli: return "terminal"
        case .token: return "dollarsign.circle"
        case .error: return "exclamationmark.triangle.fill"
        case .sse: return "antenna.radiowaves.left.and.right"
        case .tool: return "wrench.and.screwdriver"
        }
    }

    var levelColor: Color {
        switch level {
        case .info: return .secondary
        case .warn: return .orange
        case .error: return .red
        case .success: return .green
        }
    }
}

/// Debug 事件总线
/// - 单进程全局收集（最大 1000 条环形缓冲）
/// - SwiftUI 通过 @ObservedObject DebugBus 监听，自动重渲染
@MainActor
final class DebugBus: ObservableObject {
    static let shared = DebugBus()

    @Published private(set) var events: [DebugEvent] = []
    private let maxEvents = 1000

    private init() {}

    func emit(_ event: DebugEvent) {
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
    }

    /// 便捷：CLI 命令
    func cli(_ title: String, detail: String = "") {
        emit(DebugEvent(kind: .cli, level: .info, title: title, detail: detail))
    }

    /// 便捷：工具调用
    func tool(_ name: String, args: String, result: String) {
        let detail = "args=\(args.prefix(200))\n→ \(result.prefix(300))"
        emit(DebugEvent(kind: .tool, level: .success, title: name, detail: detail))
    }

    /// 便捷：Token
    func token(_ modelId: String, prompt: Int, completion: Int, costUSD: Double) {
        let title = String(
            format: "%@  prompt=%d  completion=%d  $%.4f",
            modelId, prompt, completion, costUSD
        )
        emit(DebugEvent(kind: .token, level: .info, title: title))
    }

    /// 便捷：SSE
    func sse(_ summary: String) {
        emit(DebugEvent(kind: .sse, level: .info, title: summary))
    }

    /// 便捷：错误
    func error(_ title: String, detail: String = "") {
        emit(DebugEvent(kind: .error, level: .error, title: title, detail: detail))
    }

    /// 便捷：警告
    func warn(_ title: String, detail: String = "") {
        emit(DebugEvent(kind: .error, level: .warn, title: title, detail: detail))
    }

    func clear() {
        events.removeAll()
    }
}
