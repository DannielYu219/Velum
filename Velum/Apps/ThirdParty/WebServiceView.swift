//
//  WebServiceView.swift
//  Velum
//
//  形态 2：Linux 本地 web 服务 + URL 书签。
//
//  两种子情形：
//   - runtime.url 非空：直接书签该 URL（外部或已在跑的服务），无需管理进程。
//   - runtime.command 非空：在 iSH 内起后端服务（Container），轮询就绪后加载
//     http://127.0.0.1:<port>；窗口关闭时停止后端。
//
//  注：后端进程的精确 pid 跟踪 / 端口分配（Control Plane reservePort）是后续完善项，
//  见 doc&&blueprints/92-third-party-app-program.md Phase A.2。
//

import SwiftUI
import WebKit

struct WebServiceView: UIViewRepresentable {
    let manifest: ThirdPartyAppManifest

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKPreferences()
        prefs.javaScriptEnabled = true
        config.preferences = prefs
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        context.coordinator.webView = webView

        // 起服务（或直接书签）→ 加载
        context.coordinator.start(manifest: manifest)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    /// 窗口销毁时停止后端服务。
    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject {
        weak var webView: WKWebView?
        private var serviceTask: Task<Void, Never>?

        func start(manifest: ThirdPartyAppManifest) {
            let url = URL(string: manifest.effectiveURLString)

            // 无启动命令 → 纯书签，直接加载
            guard let command = manifest.runtime.command, !command.isEmpty else {
                if let url { webView?.load(URLRequest(url: url)) }
                return
            }

            // 有启动命令 → 在 iSH 内起后端，轮询就绪后加载
            serviceTask = Task { [weak self] in
                // 后端服务进程（长驻）。consume 流以保持其运行；窗口关闭时 cancel。
                // TODO(Phase A): 经 ISHBridge 暴露 pid，dismantle 时精确 kill；
                //                端口由 Control Plane reservePort 统一分配。
                let stream = ISHBridge.shared.executeStreaming(command)
                Task {
                    do {
                        for try await _ in stream { /* 保持后端运行 */ }
                    } catch { /* 后端退出 */ }
                }

                // 轮询服务就绪（最多 ~15s）
                let probe = manifest.effectiveURLString
                for _ in 0..<30 {
                    if Task.isCancelled { return }
                    if let u = URL(string: probe),
                       let data = try? await URLSession.shared.data(from: u),
                       !data.isEmpty {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                if let url { self?.webView?.load(URLRequest(url: url)) }
            }
        }

        func teardown() {
            serviceTask?.cancel()
            serviceTask = nil
        }
    }
}
