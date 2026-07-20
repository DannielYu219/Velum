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
        guard message.name == "velum",
              let body = message.body as? [String: Any],
              let id = body["id"] as? String,
              let op = body["op"] as? String else { return }
        let args = body["args"] as? [Any] ?? []
        Task { @MainActor in
            await self.handle(id: id, op: op, args: args)
        }
    }

    // MARK: 分发 + 权限闸门

    private func handle(id: String, op: String, args: [Any]) async {
        onCall?(op, args.map { "\($0)" }.joined(separator: " "))
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
                let r = try await ISHBridge.shared.execute(cmd)
                result = "exit: \(r.exitCode)\n\(r.output)"
            case "readFile":
                guard let path = args.first as? String else { throw BridgeError.badArgs }
                result = try await ISHBridge.shared.readTextFile(path)
            case "writeFile":
                guard let path = args.first as? String,
                      let content = args.count > 1 ? args[1] as? String : nil else { throw BridgeError.badArgs }
                let n = try await ISHBridge.shared.writeTextFile(path, text: content)
                result = "wrote \(n) bytes"
            default:
                throw BridgeError.badArgs
            }
            sendBack(id: id, ok: true, value: result)
        } catch {
            sendBack(id: id, ok: false, value: error.localizedDescription)
        }
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
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
}
