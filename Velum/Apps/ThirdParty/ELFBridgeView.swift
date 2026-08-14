//
//  ELFBridgeView.swift
//  Velum
//
//  形态 1：原生 Linux ELF + CLI↔H5 桥接图形化。
//
//  布局：左侧 H5 界面（WKWebView，JS 经 WebKit JIT）+ 右侧"桥接控制台"。
//  H5 经 window.velum.*（VelumJSBridge）把调用发给 iSH 内的 Linux CLI/ELF
//  （Container 出逻辑），结果回流到 H5（WKWebView 出 UI）。控制台实时可视化
//  这条 CLI↔H5 双向通道。
//
//  当前桥接语义：H5 的每次 velum.exec(cmd) 在 iSH 内执行一条命令并返回输出
//  （request/response）。后续可扩展为常驻守护进程 + stdin/stdout 流式会话
//  （见 doc&&blueprints/92-third-party-app-program.md §4 形态 1）。
//

import SwiftUI
import WebKit

struct ELFBridgeView: View {
    let manifest: ThirdPartyAppManifest
    @State private var log: [String] = []

    var body: some View {
        HStack(spacing: 0) {
            // 左：H5 界面（同时把后端进程输出接到右侧控制台）
            ELFBridgeWebView(manifest: manifest) { op, summary in
                appendLog("→ \(op) \(summary)")
            } onBackendOutput: { line in
                // 后端流运行在后台任务, 回主线程更新 @State。
                Task { @MainActor in appendLog("后端 | \(line)") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().background(Color.white.opacity(0.1))

            // 右：桥接控制台
            console
                .frame(width: 300)
                .background(Color.black.opacity(0.18))
        }
    }

    private var console: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(.secondary)
                Text("CLI ↔ H5 桥接")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button {
                    log.removeAll()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().background(Color.white.opacity(0.1))

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if log.isEmpty {
                        Text("H5 发起的调用会显示在这里（如 velum.exec → iSH CLI/ELF）。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(log.indices, id: \.self) { i in
                        Text(log[i])
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
            }
        }
    }

    private func appendLog(_ s: String) {
        log.append(s)
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }
}

// MARK: - WebView（带桥接观测）

private struct ELFBridgeWebView: UIViewRepresentable {
    let manifest: ThirdPartyAppManifest
    let onCall: (String, String) -> Void
    let onBackendOutput: (String) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKPreferences()
        prefs.javaScriptEnabled = true
        config.preferences = prefs

        // 经自定义 scheme 从 fakefs 提供 H5 界面资源（velumapp://app/<相对路径>）。
        let schemeHandler = FakefsSchemeHandler(sandboxRoot: manifest.sandboxRoot)
        config.setURLSchemeHandler(schemeHandler, forURLScheme: FakefsSchemeHandler.scheme)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // 导航拦截: 只允许本 App 的 velumapp:// 页面(同 H5PackageView)。
        webView.navigationDelegate = context.coordinator

        let bridge = VelumJSBridge(manifest: manifest)
        bridge.onCall = { [onCall] op, summary in onCall(op, summary) }
        bridge.attach(to: webView)
        context.coordinator.bridge = bridge
        context.coordinator.schemeHandler = schemeHandler

        // [性能] exists 是 dispatch_sync 到 fs 串行队列, 移出主线程。
        let entry = manifest.entryPath
        let entryURL = FakefsSchemeHandler.entryURL(forEntry: manifest.runtime.entry)
        DispatchQueue.global(qos: .userInitiated).async { [weak webView] in
            let ok = ISHFsBridge.sharedInstance().exists(entry)
            DispatchQueue.main.async {
                guard let webView else { return }
                if ok {
                    webView.load(URLRequest(url: entryURL))
                } else {
                    webView.loadHTMLString(Self.missingPage(manifest), baseURL: nil)
                }
            }
        }

        // [修复] elfBridge 的 runtime.command 此前从未被执行（ELF 后端是空逻辑）。
        // 现在开窗即启动后端进程, 输出流入控制台, 关窗时 kill。
        context.coordinator.startBackend(manifest: manifest, onOutput: onBackendOutput)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stopBackend()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var bridge: VelumJSBridge?
        var schemeHandler: FakefsSchemeHandler?
        private var backendTask: Task<Void, Never>?

        /// 启动 manifest.runtime.command 作为 ELF 后端, 流式输出到控制台。
        /// 取消(关窗)时流终止, ISHBridge 的 onTermination 会 SIGKILL 后端进程。
        func startBackend(manifest: ThirdPartyAppManifest, onOutput: @escaping (String) -> Void) {
            guard let command = manifest.runtime.command, !command.isEmpty else { return }
            let full: String
            if let cwd = manifest.runtime.cwd, !cwd.isEmpty {
                full = "cd '\(cwd)' && \(command)"
            } else {
                full = command
            }
            backendTask = Task {
                let stream = await ISHBridge.shared.executeStreaming(full)
                do {
                    for try await line in stream {
                        onOutput(line)
                    }
                } catch {
                    onOutput("后端退出: \(error.localizedDescription)")
                }
            }
        }

        func stopBackend() {
            backendTask?.cancel()
            backendTask = nil
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url,
               url.scheme == FakefsSchemeHandler.scheme, url.host == "app" {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }

    private static func missingPage(_ manifest: ThirdPartyAppManifest) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{font-family:-apple-system,sans-serif;background:#0b0e14;color:#e6e6e6;padding:32px}
        code{background:#161b26;padding:2px 6px;border-radius:6px}</style></head><body>
        <h2>ELF 桥接界面未就绪</h2>
        <p>找不到 H5 界面入口 <code>\(manifest.entryPath)</code>。</p>
        <p>该 App 的启动命令为 <code>\(manifest.runtime.command ?? "（未设置）")</code>，
        请把配套的 H5 界面放进 <code>\(manifest.sandboxRoot)</code>。</p>
        </body></html>
        """
    }
}
