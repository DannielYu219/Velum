//
//  MCPServer.swift
//  Velum
//
//  Phase 5.1: Model Context Protocol Server 骨架
//
//  实现 JSON-RPC 2.0 over HTTP，提供 tools/list 和 tools/call 两个方法。
//  每个 tool 映射到 VelumAction 或直接调 ISHBridge，让外部 Agent 客户端
//  可以通过标准 MCP 协议控制 Velum 桌面和 iSH。
//
//  协议规范参考：https://spec.modelcontextprotocol.io/
//

import Foundation
import Network

// MARK: - MCP Types

public struct MCPTool: Codable, Hashable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONSchema

    public init(name: String, description: String, inputSchema: JSONSchema) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct JSONSchema: Codable, Hashable, Sendable {
    public let type: String
    public let properties: [String: Property]?
    public let required: [String]?

    public init(type: String = "object", properties: [String: Property]? = nil, required: [String]? = nil) {
        self.type = type
        self.properties = properties
        self.required = required
    }

    public struct Property: Codable, Hashable, Sendable {
        public let type: String
        public let description: String
        public let `enum`: [String]?

        public init(type: String, description: String, enum: [String]? = nil) {
            self.type = type
            self.description = description
            self.enum = `enum`
        }
    }
}

public struct MCPToolResult: Codable, Sendable {
    public let content: [Content]
    public let isError: Bool

    public init(text: String, isError: Bool = false) {
        self.content = [.init(type: "text", text: text)]
        self.isError = isError
    }

    public struct Content: Codable, Sendable {
        public let type: String
        public let text: String
    }
}

// MARK: - JSON-RPC types

private struct JSONRPCRequest: Codable {
    let jsonrpc: String
    let id: Int
    let method: String
    let params: [String: AnyCodable]?
}

private struct JSONRPCResponse: Codable {
    let jsonrpc: String
    let id: Int
    let result: AnyCodable?
    let error: RPCError?
}

private struct RPCError: Codable {
    let code: Int
    let message: String
}

private struct AnyCodable: Codable {
    let value: Any
    init(_ value: Any) { self.value = value }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(String.self) { self.value = v }
        else if let v = try? container.decode(Int.self) { self.value = v }
        else if let v = try? container.decode(Double.self) { self.value = v }
        else if let v = try? container.decode(Bool.self) { self.value = v }
        else if let v = try? container.decode([String: AnyCodable].self) {
            self.value = v.mapValues { $0.value }
        }
        else if let v = try? container.decode([AnyCodable].self) {
            self.value = v.map { $0.value }
        }
        else { self.value = NSNull() }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as String:  try container.encode(v)
        case let v as Int:     try container.encode(v)
        case let v as Double:  try container.encode(v)
        case let v as Bool:    try container.encode(v)
        case let v as [String: Any]:
            try container.encode(v.mapValues { AnyCodable($0) })
        case let v as [Any]:
            try container.encode(v.map { AnyCodable($0) })
        case is NSNull:        try container.encodeNil()
        default:               try container.encodeNil()
        }
    }
}

// MARK: - MCPServer

public actor MCPServer {

    public static let shared = MCPServer()

    // MARK: - State

    private var listener: NWListener?
    private let port: UInt16 = 8765
    private var connections: [UUID: MCPConnection] = [:]

    private init() {}

    // MARK: - Public API

    public func start() async throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        let l = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))
        l.newConnectionHandler = { [weak self] conn in
            Task { await self?.handle(conn) }
        }
        l.start(queue: .global(qos: .utility))
        listener = l
        print("[MCPServer] listening on 127.0.0.1:\(port)")
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for conn in connections.values { conn.cancel() }
        connections.removeAll()
    }

    public var isRunning: Bool { listener != nil }

    // MARK: - Connection handling

    private func handle(_ nw: NWConnection) async {
        let id = UUID()
        let conn = MCPConnection(nw)
        connections[id] = conn
        let weakSelf = self
        await conn.start { request in
            await weakSelf.route(request)
        }
        connections.removeValue(forKey: id)
    }

    // MARK: - Routing

    private func route(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        switch request.method {
        case "initialize":
            return JSONRPCResponse(
                jsonrpc: "2.0", id: request.id,
                result: AnyCodable([
                    "protocolVersion": "2024-11-05",
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "velum", "version": "1.0"],
                ]),
                error: nil
            )
        case "tools/list":
            return JSONRPCResponse(
                jsonrpc: "2.0", id: request.id,
                result: AnyCodable(["tools": Self.allTools.map { $0.encodeToDict() }]),
                error: nil
            )
        case "tools/call":
            return await handleToolCall(request)
        default:
            return JSONRPCResponse(
                jsonrpc: "2.0", id: request.id, result: nil,
                error: RPCError(code: -32601, message: "Method not found: \(request.method)")
            )
        }
    }

    private func handleToolCall(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        guard let params = request.params,
              let toolName = params["name"]?.value as? String else {
            return JSONRPCResponse(
                jsonrpc: "2.0", id: request.id, result: nil,
                error: RPCError(code: -32602, message: "Missing 'name' in params")
            )
        }
        let args = (params["arguments"]?.value as? [String: Any]) ?? [:]

        do {
            let result = try await Self.executeTool(name: toolName, args: args)
            return JSONRPCResponse(
                jsonrpc: "2.0", id: request.id,
                result: AnyCodable(result.encodeToDict()),
                error: nil
            )
        } catch {
            let result = MCPToolResult(text: "Error: \(error.localizedDescription)", isError: true)
            return JSONRPCResponse(
                jsonrpc: "2.0", id: request.id,
                result: AnyCodable(result.encodeToDict()),
                error: nil
            )
        }
    }

    // MARK: - Tool registry

    public static let allTools: [MCPTool] = [
        // Shell
        MCPTool(
            name: "exec_shell",
            description: "在 iSH 内执行 shell 命令并返回完整输出",
            inputSchema: JSONSchema(
                properties: [
                    "command": .init(type: "string", description: "要执行的 shell 命令"),
                ],
                required: ["command"]
            )
        ),
        // Filesystem
        MCPTool(
            name: "list_dir",
            description: "列出 iSH fakefs 中指定目录的内容",
            inputSchema: JSONSchema(
                properties: [
                    "path": .init(type: "string", description: "目录绝对路径，如 /etc"),
                ],
                required: ["path"]
            )
        ),
        MCPTool(
            name: "read_file",
            description: "读取 iSH fakefs 中的文件内容",
            inputSchema: JSONSchema(
                properties: [
                    "path": .init(type: "string", description: "文件绝对路径"),
                ],
                required: ["path"]
            )
        ),
        MCPTool(
            name: "write_file",
            description: "写入内容到 iSH fakefs 中的文件",
            inputSchema: JSONSchema(
                properties: [
                    "path": .init(type: "string", description: "文件绝对路径"),
                    "content": .init(type: "string", description: "要写入的内容"),
                ],
                required: ["path", "content"]
            )
        ),
        // System
        MCPTool(
            name: "list_processes",
            description: "列出 iSH 内正在运行的进程",
            inputSchema: JSONSchema()
        ),
        MCPTool(
            name: "get_system_info",
            description: "获取系统信息（内核版本、内存、运行时间）",
            inputSchema: JSONSchema()
        ),
        // Desktop
        MCPTool(
            name: "launch_app",
            description: "启动 Velum 桌面应用。files/terminal 可通过 path 参数指定初始路径",
            inputSchema: JSONSchema(
                properties: [
                    "app": .init(type: "string", description: "应用名",
                                 enum: ["terminal", "files", "settings", "about"]),
                    "path": .init(type: "string", description: "初始路径（仅 files/terminal 有效），如 /etc"),
                ],
                required: ["app"]
            )
        ),
        MCPTool(
            name: "switch_tty",
            description: "切换终端到指定 TTY (1-7)",
            inputSchema: JSONSchema(
                properties: [
                    "tty": .init(type: "integer", description: "TTY 编号 1-7"),
                ],
                required: ["tty"]
            )
        ),
    ]

    // MARK: - Tool execution

    public static func executeTool(name: String, args: [String: Any]) async throws -> MCPToolResult {
        switch name {
        // Shell
        case "exec_shell":
            guard let cmd = args["command"] as? String else {
                throw MCPError.missingArgument("command")
            }
            let r = try await ISHBridge.shared.execute("\(cmd) 2>&1")
            let text = "exit: \(r.exitCode)\n\(r.output)"
            return MCPToolResult(text: text, isError: !r.isSuccess)

        // Filesystem
        case "list_dir":
            guard let path = args["path"] as? String else {
                throw MCPError.missingArgument("path")
            }
            let entries = try await ISHBridge.shared.listDir(path)
            let lines = entries.map { e -> String in
                let type = e.isDirectory ? "d" : (e.isSymlink ? "l" : "-")
                return "\(type) \(e.permissionString) \(e.formattedSize.padding(toLength: 8, withPad: " ", startingAt: 0)) \(e.name)"
            }
            return MCPToolResult(text: "total \(entries.count)\n" + lines.joined(separator: "\n"))

        case "read_file":
            guard let path = args["path"] as? String else {
                throw MCPError.missingArgument("path")
            }
            let text = try await ISHBridge.shared.readTextFile(path)
            return MCPToolResult(text: text)

        case "write_file":
            guard let path = args["path"] as? String,
                  let content = args["content"] as? String else {
                throw MCPError.missingArgument("path or content")
            }
            let written = try await ISHBridge.shared.writeTextFile(path, text: content)
            return MCPToolResult(text: "已写入 \(written) 字节到 \(path)")

        // System
        case "list_processes":
            let r = try await ISHBridge.shared.execute("ps aux 2>&1")
            return MCPToolResult(text: r.output)

        case "get_system_info":
            let unameR = try await ISHBridge.shared.execute("uname -a 2>&1")
            let uptimeR = try await ISHBridge.shared.execute("cat /proc/uptime 2>&1")
            let memR = try await ISHBridge.shared.execute("cat /proc/meminfo 2>&1 | head -5")
            let text = """
            内核: \(unameR.output)
            运行时间: \(uptimeR.output)
            内存:
            \(memR.output)
            """
            return MCPToolResult(text: text)

        // Desktop
        case "launch_app":
            guard let appStr = args["app"] as? String,
                  let app = VelumApp(rawValue: appStr) else {
                throw MCPError.invalidArgument("app", "必须是 terminal/files/settings/about 之一")
            }
            let contextPath = args["path"] as? String
            await MainActor.run {
                VelumControl.shared.perform(.launchApp(AppManifest(name: appStr)))
                WindowManager.shared.open(app, contextPath: contextPath)
            }
            let pathInfo = contextPath.map { "（路径: \($0)）" } ?? ""
            return MCPToolResult(text: "已启动 \(appStr)\(pathInfo)")

        case "switch_tty":
            guard let tty = args["tty"] as? Int, (1...7).contains(tty) else {
                throw MCPError.invalidArgument("tty", "必须是 1-7 的整数")
            }
            await MainActor.run {
                VelumControl.shared.perform(.switchTTY(tty))
            }
            return MCPToolResult(text: "已切换到 TTY \(tty)")

        default:
            throw MCPError.unknownTool(name)
        }
    }
}

// MARK: - Errors

public enum MCPError: LocalizedError {
    case missingArgument(String)
    case invalidArgument(String, String)
    case unknownTool(String)

    public var errorDescription: String? {
        switch self {
        case .missingArgument(let name): return "缺少参数: \(name)"
        case .invalidArgument(let name, let reason): return "参数无效: \(name) - \(reason)"
        case .unknownTool(let name): return "未知工具: \(name)"
        }
    }
}

// MARK: - Connection wrapper

private final class MCPConnection: @unchecked Sendable {
    private let nw: NWConnection
    private var buffer = Data()
    private var lengthPrefixBuffer = Data()

    init(_ nw: NWConnection) { self.nw = nw }

    func start(handler: @escaping (JSONRPCRequest) async -> JSONRPCResponse) {
        nw.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.receive(handler: handler)
            case .failed, .cancelled: self?.cancel()
            default: break
            }
        }
        nw.start(queue: .global(qos: .utility))
    }

    func cancel() { nw.cancel() }

    private func receive(handler: @escaping (JSONRPCRequest) async -> JSONRPCResponse) {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.processBuffer(handler: handler)
            }
            if isComplete || error != nil { self.cancel(); return }
            self.receive(handler: handler)
        }
    }

    /// 简化协议：每行一个 JSON-RPC 请求（类似 LSP 但用换行而非 Content-Length）
    private func processBuffer(handler: @escaping (JSONRPCRequest) async -> JSONRPCResponse) {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let data = try? JSONDecoder().decode(JSONRPCRequest.self, from: Data(line)) else { continue }
            Task {
                let response = await handler(data)
                if let respData = try? JSONEncoder().encode(response),
                   var str = String(data: respData, encoding: .utf8) {
                    str += "\n"
                    self.nw.send(content: str.data(using: .utf8), completion: .contentProcessed { _ in })
                }
            }
        }
    }
}

// MARK: - Encodable -> Dict helper

private extension Encodable {
    func encodeToDict() -> [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict
    }
}
