//
//  MCPClient.swift
//  Velum
//
//  Phase 5.3: MCP 客户端 — 连接到本机 MCPServer，调用 tools
//
//  通过 TCP 连接 127.0.0.1:8765，发送 JSON-RPC 请求，接收 JSON-RPC 响应。
//  使用换行分隔的 JSON-RPC 协议（类似 LSP 但简化）。
//

import Foundation
import Network

public final class MCPClient: @unchecked Sendable {

    private let endpoint: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "app.velum.mcp-client")
    private var connection: NWConnection?
    private let lock = NSLock()
    private var nextId: Int = 1

    public init(endpoint: String = "127.0.0.1", port: UInt16 = 8765) {
        self.endpoint = endpoint
        self.port = port
    }

    // MARK: - Public API

    /// 列出可用工具
    public func listTools() async throws -> [MCPTool] {
        let result: [String: Any] = try await send(method: "tools/list", params: nil)
        guard let toolsArray = result["tools"] as? [[String: Any]] else { return [] }
        return toolsArray.compactMap { dict in
            guard let data = try? JSONSerialization.data(withJSONObject: dict),
                  let tool = try? JSONDecoder().decode(MCPTool.self, from: data) else { return nil }
            return tool
        }
    }

    /// 调用工具
    public func callTool(name: String, args: [String: Any]) async throws -> MCPToolResult {
        let params: [String: Any] = [
            "name": name,
            "arguments": args,
        ]
        let result: [String: Any] = try await send(method: "tools/call", params: params)
        guard let data = try? JSONSerialization.data(withJSONObject: result),
              let parsed = try? JSONDecoder().decode(MCPToolResult.self, from: data) else {
            return MCPToolResult(text: "(无法解析结果)")
        }
        return parsed
    }

    // MARK: - Private

    private func ensureConnected() async throws -> NWConnection {
        lock.lock(); defer { lock.unlock() }
        if let conn = connection, conn.state == .ready { return conn }

        let host = NWEndpoint.Host(endpoint)
        let port = NWEndpoint.Port(integerLiteral: port)
        let conn = NWConnection(host: host, port: port, using: .tcp)
        conn.start(queue: queue)
        connection = conn

        // 等待连接就绪
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: cont.resume()
                case .failed(let err): cont.resume(throwing: err)
                case .cancelled: cont.resume(throwing: MCPClientError.connectionFailed)
                default: break
                }
            }
        }
        return conn
    }

    private func send(method: String, params: [String: Any]?) async throws -> [String: Any] {
        let conn = try await ensureConnected()

        let id = nextRequestId()
        var request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
        ]
        if let params { request["params"] = params }

        let data = try JSONSerialization.data(withJSONObject: request)
        guard var line = String(data: data, encoding: .utf8) else {
            throw MCPClientError.encodingFailed
        }
        line += "\n"

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
            conn.send(content: line.data(using: .utf8), completion: .contentProcessed { [weak self] error in
                if let error { cont.resume(throwing: error); return }
                self?.waitForResponse(id: id, on: conn, cont: cont)
            })
        }
    }

    private func waitForResponse(id: Int, on conn: NWConnection,
                                  cont: CheckedContinuation<[String: Any], Error>) {
        var buffer = Data()
        func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error); return }
                if let data { buffer.append(data) }

                // 尝试按行解析
                while let newlineIdx = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[buffer.startIndex..<newlineIdx]
                    buffer.removeSubrange(buffer.startIndex...newlineIdx)

                    guard let lineString = String(data: Data(lineData), encoding: .utf8),
                          let lineData = lineString.data(using: .utf8),
                          let parsed = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                        continue
                    }

                    // 检查 id 是否匹配
                    if let respId = parsed["id"] as? Int, respId == id {
                        if let error = parsed["error"] as? [String: Any],
                           let message = error["message"] as? String {
                            cont.resume(throwing: MCPClientError.serverError(message))
                        } else if let result = parsed["result"] as? [String: Any] {
                            cont.resume(returning: result)
                        } else {
                            cont.resume(returning: [:])
                        }
                        return
                    }
                }

                if isComplete {
                    cont.resume(throwing: MCPClientError.connectionClosed)
                    return
                }
                receive()
            }
        }
        receive()
    }

    private func nextRequestId() -> Int {
        lock.lock(); defer { lock.unlock() }
        let id = nextId
        nextId += 1
        return id
    }
}

// MARK: - Errors

public enum MCPClientError: LocalizedError {
    case connectionFailed
    case connectionClosed
    case encodingFailed
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .connectionFailed: return "无法连接到 MCP Server"
        case .connectionClosed: return "MCP 连接已关闭"
        case .encodingFailed:   return "请求编码失败"
        case .serverError(let msg): return "MCP Server 错误: \(msg)"
        }
    }
}
