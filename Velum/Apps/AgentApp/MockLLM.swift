//
//  MockLLM.swift
//  Velum
//
//  Phase 5.3: Mock LLM — 模拟大语言模型响应
//
//  当前基于关键词匹配，模拟 LLM 决定调用 tool 的行为。
//  后续接入真实 LLM 时，替换此文件的实现即可。
//

import Foundation

struct MockLLM {

    struct Response {
        let text: String
        let toolCall: ToolCall?
    }

    struct ToolCall {
        let name: String
        let arguments: [String: Any]
    }

    // MARK: - Respond

    static func respond(to userQuery: String, availableTools: [String]) async throws -> Response {
        let query = userQuery.lowercased()

        // 列出目录
        if query.contains("列出") || query.contains("ls") || query.contains("目录") || query.contains("文件") {
            if query.contains("/etc") || query.contains("etc") {
                return Response(
                    text: "好的，我来列出 /etc 目录的内容。",
                    toolCall: ToolCall(name: "list_dir", arguments: ["path": "/etc"])
                )
            }
            if query.contains("/root") || query.contains("root") {
                return Response(
                    text: "好的，我来列出 /root 目录的内容。",
                    toolCall: ToolCall(name: "list_dir", arguments: ["path": "/root"])
                )
            }
            if query.contains("/") {
                // 尝试提取路径
                if let path = extractPath(from: userQuery) {
                    return Response(
                        text: "好的，我来列出 \(path) 目录的内容。",
                        toolCall: ToolCall(name: "list_dir", arguments: ["path": path])
                    )
                }
            }
            return Response(
                text: "好的，我来列出根目录的内容。",
                toolCall: ToolCall(name: "list_dir", arguments: ["path": "/"])
            )
        }

        // 执行 shell 命令
        if query.contains("执行") || query.contains("运行") || query.contains("run") {
            if let cmd = extractCommand(from: userQuery) {
                return Response(
                    text: "好的，我来执行 `\(cmd)`。",
                    toolCall: ToolCall(name: "exec_shell", arguments: ["command": cmd])
                )
            }
        }

        // 系统信息
        if query.contains("系统信息") || query.contains("system info") || query.contains("uname") {
            return Response(
                text: "好的，我来获取系统信息。",
                toolCall: ToolCall(name: "get_system_info", arguments: [:])
            )
        }

        // 进程列表
        if query.contains("进程") || query.contains("ps") || query.contains("process") {
            return Response(
                text: "好的，我来列出当前运行的进程。",
                toolCall: ToolCall(name: "list_processes", arguments: [:])
            )
        }

        // 读取文件
        if query.contains("读取") || query.contains("cat") || query.contains("read") {
            if let path = extractPath(from: userQuery) {
                return Response(
                    text: "好的，我来读取 \(path) 的内容。",
                    toolCall: ToolCall(name: "read_file", arguments: ["path": path])
                )
            }
        }

        // 启动应用
        if query.contains("打开") || query.contains("启动") || query.contains("launch") {
            if query.contains("终端") || query.contains("terminal") {
                let path = extractPath(from: userQuery)
                return Response(
                    text: "好的，我来打开终端。\(path.map { "（路径: \($0)）" } ?? "")",
                    toolCall: ToolCall(name: "launch_app",
                                       arguments: path.map { ["app": "terminal", "path": $0] } ?? ["app": "terminal"])
                )
            }
            if query.contains("文件") || query.contains("files") {
                let path = extractPath(from: userQuery)
                return Response(
                    text: "好的，我来打开文件管理器。\(path.map { "（路径: \($0)）" } ?? "")",
                    toolCall: ToolCall(name: "launch_app",
                                       arguments: path.map { ["app": "files", "path": $0] } ?? ["app": "files"])
                )
            }
            if query.contains("设置") || query.contains("settings") {
                return Response(
                    text: "好的，我来打开设置。",
                    toolCall: ToolCall(name: "launch_app", arguments: ["app": "settings"])
                )
            }
        }

        // 默认回复
        return Response(
            text: """
            我理解你说的是「\(userQuery)」。

            我目前支持以下操作：
            - 列出目录（如「列出 /etc 下文件」）
            - 执行 shell 命令（如「执行 uname -a」）
            - 读取文件（如「读取 /etc/hostname」）
            - 查看系统信息（如「系统信息」）
            - 查看进程列表（如「进程列表」）
            - 启动应用（如「打开终端」）

            后续接入真实 LLM 后可以理解更复杂的指令。
            """,
            toolCall: nil
        )
    }

    // MARK: - Summarize

    static func summarize(userQuery: String, toolName: String, toolResult: String) async throws -> String {
        // Mock：截取结果前几行作为总结
        let lines = toolResult.split(separator: "\n")
        if lines.count > 20 {
            return "执行完成，共 \(lines.count) 行输出。前 10 行：\n" + lines.prefix(10).joined(separator: "\n")
        }
        return "执行完成，结果如下：\n\(toolResult)"
    }

    // MARK: - Parsing helpers

    private static func extractPath(from text: String) -> String? {
        // 匹配 /开头 的路径
        let pattern = #"(/\S+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = regex.firstMatch(in: text, options: [], range: range),
           match.numberOfRanges > 1,
           let r = Range(match.range(at: 1), in: text) {
            return String(text[r])
        }
        return nil
    }

    private static func extractCommand(from text: String) -> String? {
        // 提取引号内的命令
        let patterns = [
            #"`([^`]+)`"#,
            #"\"([^\"]+)\""#,
            #"'([^']+)'"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               match.numberOfRanges > 1,
               let r = Range(match.range(at: 1), in: text) {
                return String(text[r])
            }
        }
        return nil
    }
}
