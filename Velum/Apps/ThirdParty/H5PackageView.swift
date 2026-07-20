//
//  H5PackageView.swift
//  Velum
//
//  形态 3：H5/JS 包。WKWebView 直接加载 fakefs 内的 H5 包入口文件，JS 经 WebKit
//  JIT 执行——这是"不依赖 Linux、纯 WebView 作为 JIT 引擎"的形态。
//
//  包资产位于 manifest.sandboxRoot（fakefs），入口为 manifest.entryPath。
//  经 VelumJSBridge 获得 window.velum.* 系统资源能力（受 manifest 权限约束）。
//

import SwiftUI
import WebKit

struct H5PackageView: UIViewRepresentable {
    let manifest: ThirdPartyAppManifest

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKPreferences()
        prefs.javaScriptEnabled = true
        config.preferences = prefs
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsInlineMediaPlayback = true
        // 允许 H5 包访问同目录本地资源
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        // 挂 JS 桥（window.velum.*）
        let bridge = VelumJSBridge(manifest: manifest)
        bridge.attach(to: webView)
        context.coordinator.bridge = bridge

        // 从 fakefs 加载入口文件
        let root = URL(fileURLWithPath: manifest.sandboxRoot, isDirectory: true)
        let entry = URL(fileURLWithPath: manifest.entryPath)
        if FileManager.default.fileExists(atPath: manifest.entryPath) {
            webView.loadFileURL(entry, allowingReadAccessTo: root)
        } else {
            webView.loadHTMLString(Self.missingPage(manifest), baseURL: nil)
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        /// 持有桥，避免其作为 messageHandler 被提前释放。
        var bridge: VelumJSBridge?
    }

    private static func missingPage(_ manifest: ThirdPartyAppManifest) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{font-family:-apple-system,sans-serif;background:#0b0e14;color:#e6e6e6;padding:32px}
        code{background:#161b26;padding:2px 6px;border-radius:6px}</style></head><body>
        <h2>H5 包未就绪</h2>
        <p>找不到入口文件 <code>\(manifest.entryPath)</code>。</p>
        <p>请把 H5 资产放进该 App 的 fakefs 沙箱目录 <code>\(manifest.sandboxRoot)</code>，
        或经"软件中心"安装完整 bundle。</p>
        </body></html>
        """
    }
}
