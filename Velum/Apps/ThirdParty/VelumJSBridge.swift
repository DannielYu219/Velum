//
//  VelumJSBridge.swift
//  Velum
//
//  H5 ↔ Velum 的 JavaScript 桥（WKScriptMessageHandler）。
//
//  这是三种 App 形态共享的"系统资源调用"入口：H5 经 `window.velum.*` 调用
//  host 能力（剪贴板 / 通知 / 在 iSH 执行命令 / 读写 fakefs 文件）。每个调用
//  都先过 manifest 的权限闸门（`ThirdPartyAppManifest.permissions`），未声明则拒绝。
//
//  对应 doc&&blueprints/92-third-party-app-program.md §5（velum-ctl 资源模型的
//  H5 侧实现；guest 内 CLI 的 velum-ctl 走 unix socket，是同一权限模型的另一入口）。
//
//  注入的 JS API（Promise 风格）：
//    velum.clipboardGet()            → string
//    velum.clipboardSet(text)        → "ok"
//    velum.notify(title, body)       → "ok"
//    velum.exec(command)             → "exit: N\n<output>"
//    velum.readFile(path)            → string
//    velum.writeFile(path, content)  → "wrote N bytes"
//

import Foundation
import WebKit
import UIKit
import UserNotifications

@MainActor
final class VelumJSBridge: NSObject, WKScriptMessageHandler {

    private let manifest: ThirdPartyAppManifest
    private weak var webView: WKWebView?
    private var pending: [String: (Result<String, Error>)->Void] = [:]

    /// 观测钩子：每次 H5 发起调用时触发（op + 参数摘要）。ELF 桥接控制台用它可视化流量。
    var onCall: ((String, String) -> Void)?

    /// 桥接错误。
    enum BridgeError: LocalizedError {
        case denied(String)
        case badArgs
        var errorDescription: String? {
            switch self {
            case .denied(let p): return "权限被拒绝：\(p)（未在 manifest 声明）"
            case .badArgs:       return "参数错误"
            }
        }
    }

    init(manifest: ThirdPartyAppManifest) {
        self.manifest = manifest
        super.init()
    }

    /// 把桥挂到一个 WKWebView：注册 messageHandler + 注入 window.velum。
    /// 调用方应为每个 WebView 使用独立的 WKWebViewConfiguration（本框架默认如此），
    /// 因此这里直接 add，无需去重。
    func attach(to webView: WKWebView) {
        self.webView = webView
        let ucc = webView.configuration.userContentController
        ucc.add(self, name: "velum")
        ucc.addUserScript(Self.velumAPI)
    }

    // MARK: WKScriptMessageHandler

    nonisolated func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        // WKScriptMessage 的属性在 SDK 里是 MainActor 隔离, 检查统一放进主线程 Task 执行。
        // 来源校验: 只接受主 frame 且来自本 App 的 velumapp://app 页面的消息。
        // 防止 App 导航/被 iframe 注入远程页面后, 远程页面继续持有 window.velum 的全部能力。
        Task { @MainActor in
            guard message.name == "velum",
                  message.frameInfo.isMainFrame,
                  message.frameInfo.request.url?.scheme == FakefsSchemeHandler.scheme,
                  message.frameInfo.request.url?.host == "app",
                  let body = message.body as? [String: Any],
                  let id = body["id"] as? String,
                  let op = body["op"] as? String else { return }
            let args = body["args"] as? [Any] ?? []
            await self.handle(id: id, op: op, args: args)
        }
    }

    // MARK: 分发 + 权限闸门

    private func handle(id: String, op: String, args: [Any]) async {
        // 日志脱敏: 只记录 op 与参数摘要, 不把完整命令/文件内容送进控制台。
        let summary = args.map { "\($0)" }.joined(separator: " ")
        onCall?(op, String(summary.prefix(80)))
        do {
            let result: String
            switch op {
            case "clipboardGet":
                try require("clipboard")
                result = UIPasteboard.general.string ?? ""
            case "clipboardSet":
                try require("clipboard")
                UIPasteboard.general.string = (args.first as? String) ?? ""
                result = "ok"
            case "notify":
                try require("notify")
                result = try await postNotification(
                    title: (args.first as? String) ?? "Velum",
                    body: (args.count > 1 ? args[1] as? String : nil) ?? ""
                )
            case "exec":
                try require("exec")
                guard let cmd = args.first as? String else { throw BridgeError.badArgs }
                // [性能/安全] 默认 30s 超时: 防止 H5 页面触发死循环/挂起命令
                // 拖垮整个桌面(超时自动 SIGKILL guest 进程)。
                let r = try await ISHBridge.shared.execute(cmd, timeout: 30)
                result = "exit: \(r.exitCode)\n\(r.output)"
            case "readFile":
                try require("fs")
                guard let path = args.first as? String, !path.isEmpty else { throw BridgeError.badArgs }
                guard let safe = await sandboxedPath(path) else {
                    throw BridgeError.denied("路径越出应用沙箱")
                }
                result = try await ISHBridge.shared.readTextFile(safe)
            case "writeFile":
                try require("fs")
                guard let path = args.first as? String, !path.isEmpty,
                      let content = args.count > 1 ? args[1] as? String : nil else { throw BridgeError.badArgs }
                guard let safe = await sandboxedPath(path) else {
                    throw BridgeError.denied("路径越出应用沙箱")
                }
                let n = try await ISHBridge.shared.writeTextFile(safe, text: content)
                result = "wrote \(n) bytes"
            default:
                throw BridgeError.badArgs
            }
            sendBack(id: id, ok: true, value: result)
        } catch {
            sendBack(id: id, ok: false, value: error.localizedDescription)
        }
    }

    // MARK: 路径沙箱

    /// 把 H5 请求的路径解析到本 App 沙箱根内（与 FakefsSchemeHandler 共用同一套语义：
    /// 相对路径按沙箱内路径解释、绝对路径必须落在 sandboxRoot 前缀内、逐段解析符号链接）。
    /// 越界返回 nil。
    /// [性能] 解析会逐段做 dispatch_sync 的 fs 调用, 必须离开主线程执行。
    private func sandboxedPath(_ raw: String) async -> String? {
        let root = manifest.sandboxRoot
        return await Task.detached(priority: .userInitiated) {
            FakefsSchemeHandler.sandboxedPath(raw, sandboxRoot: root,
                                              fs: ISHFsBridge.sharedInstance())
        }.value
    }

    /// 权限闸门：未在 manifest 声明的能力一律拒绝。
    private func require(_ permission: String) throws {
        guard manifest.hasPermission(permission) else {
            throw BridgeError.denied(permission)
        }
    }

    private func postNotification(title: String, body: String) async throws -> String {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try await center.add(req)
        return "ok"
    }

    private func sendBack(id: String, ok: Bool, value: String) {
        let obj: [String: Any] = ["id": id, "ok": ok, "value": value]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__velumRecv && window.__velumRecv(\(json))")
    }

    // MARK: 注入脚本

    /// 注入到每个页面的 window.velum API（Promise 风格）。
    private static let velumAPI = WKUserScript(source: """
    (function(){
      var seq = 0, pending = {};
      window.__velumRecv = function(r){
        var p = pending[r.id]; if(!p) return; delete pending[r.id];
        if(r.ok){ p.resolve(r.value); } else { p.reject(r.value); }
      };
      function call(op, args){
        return new Promise(function(resolve, reject){
          var id = 'c' + (seq++);
          pending[id] = { resolve: resolve, reject: reject };
          window.webkit.messageHandlers.velum.postMessage({ id: id, op: op, args: args || [] });
        });
      }
      window.velum = {
        clipboardGet: function(){ return call('clipboardGet'); },
        clipboardSet: function(t){ return call('clipboardSet', [t]); },
        notify: function(title, body){ return call('notify', [title, body]); },
        exec: function(cmd){ return call('exec', [cmd]); },
        readFile: function(path){ return call('readFile', [path]); },
        writeFile: function(path, content){ return call('writeFile', [path, content]); }
      };
    })();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
}
