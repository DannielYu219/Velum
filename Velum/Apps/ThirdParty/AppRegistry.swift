//
//  AppRegistry.swift
//  Velum
//
//  第三方 App 注册表：安装 / 卸载 / 查询 / 持久化（UserDefaults），并内置三个
//  演示 App（每种形态各一），便于框架联调。
//
//  与 WindowManager 的衔接：`open(_:contextPath:)` 经 WindowManager 开窗，
//  AppWindow.thirdPartyId 指向本注册表里的 manifest，由 ThirdPartyAppHost 渲染。
//

import Foundation
import SwiftUI

@MainActor
public final class AppRegistry: ObservableObject {

    public static let shared = AppRegistry()

    @Published public private(set) var installed: [ThirdPartyAppManifest] = []

    private let storeKey = "velum.installedApps.v1"
    private let seededKey = "velum.demoAppsSeeded.v1"

    private init() {
        load()
    }

    // MARK: 查询

    public func app(_ id: String) -> ThirdPartyAppManifest? {
        installed.first { $0.id == id }
    }

    public func apps(ofForm form: AppForm) -> [ThirdPartyAppManifest] {
        installed.filter { $0.form == form }
    }

    // MARK: 安装 / 卸载

    public func install(_ manifest: ThirdPartyAppManifest) {
        if let idx = installed.firstIndex(where: { $0.id == manifest.id }) {
            installed[idx] = manifest
        } else {
            installed.append(manifest)
        }
        persist()
    }

    public func uninstall(_ id: String) {
        installed.removeAll { $0.id == id }
        persist()
    }

    /// 经 WindowManager 打开一个第三方 App 窗口。
    @discardableResult
    public func open(_ id: String, contextPath: String? = nil) -> AppWindow? {
        guard app(id) != nil else { return nil }
        return WindowManager.shared.openThirdParty(id: id, contextPath: contextPath)
    }

    // MARK: 持久化

    private func persist() {
        if let data = try? JSONEncoder().encode(installed) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let list = try? JSONDecoder().decode([ThirdPartyAppManifest].self, from: data) else { return }
        installed = list
    }

    // MARK: 演示 App（首次 kernel ready 后调用）

    /// 注入三个演示 App（每形态一个），并把 H5 演示包写进 fakefs。幂等。
    public func seedDemosIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }

        // 形态 3：H5 包（纯 WKWebView，JS 即 JIT）
        install(ThirdPartyAppManifest(
            id: "demo.h5",
            name: "H5 演示",
            form: .h5Package,
            category: "development",
            author: "Velum",
            permissions: ["clipboard", "notify"],
            runtime: .init(entry: "index.html")
        ))

        // 形态 1：ELF 桥接（H5 界面 ↔ iSH CLI/ELF）
        install(ThirdPartyAppManifest(
            id: "demo.elf",
            name: "ELF 桥接演示",
            form: .elfBridge,
            category: "development",
            author: "Velum",
            permissions: ["exec"],
            runtime: .init(command: "uname -a", entry: "index.html")
        ))

        // 形态 2：Web 服务（URL 书签）
        install(ThirdPartyAppManifest(
            id: "demo.web",
            name: "Web 书签演示",
            form: .webService,
            category: "development",
            author: "Velum",
            runtime: .init(url: "https://example.com")
        ))

        // 把 H5 演示包写进 fakefs（best-effort；kernel 未就绪时跳过）
        await writeDemoFiles()

        UserDefaults.standard.set(true, forKey: seededKey)
    }

    private func writeDemoFiles() async {
        let bridge = ISHBridge.shared
        _ = try? await bridge.execute("mkdir -p /var/lib/velum/apps/demo.h5 /var/lib/velum/apps/demo.elf")
        _ = try? await bridge.writeTextFile("/var/lib/velum/apps/demo.h5/index.html", text: Self.h5DemoHTML)
        _ = try? await bridge.writeTextFile("/var/lib/velum/apps/demo.elf/index.html", text: Self.elfDemoHTML)
    }

    // MARK: 演示 H5（内联，避免 bundle 资源依赖）

    /// 形态 3 演示：展示 window.velum JS 桥（clipboard / notify / exec）。
    private static let h5DemoHTML = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>H5 演示</title>
    <style>
      body{font-family:-apple-system,sans-serif;background:#0b0e14;color:#e6e6e6;padding:24px}
      h1{font-size:20px} button{padding:10px 16px;margin:6px 6px 0 0;border-radius:10px;border:0;background:#3a7afe;color:#fff;font-size:15px}
      pre{background:#161b26;padding:12px;border-radius:10px;white-space:pre-wrap;word-break:break-all}
    </style></head><body>
    <h1>形态 3 · H5 包</h1>
    <p>本页面由 WKWebView 直接运行（JS 经 WebKit JIT），不依赖 Linux。</p>
    <button onclick="getClip()">读剪贴板</button>
    <button onclick="setClip()">写剪贴板</button>
    <button onclick="notify()">发通知</button>
    <button onclick="runCmd()">在 iSH 跑 uname -a</button>
    <pre id="out">点上方按钮试试 ↑</pre>
    <script>
      function out(t){document.getElementById('out').textContent=t}
      function getClip(){velum.clipboardGet().then(out).catch(out)}
      function setClip(){velum.clipboardSet('Hello from Velum H5 @ '+new Date().toLocaleTimeString()).then(function(){out('已写入剪贴板')}).catch(out)}
      function notify(){velum.notify('Velum','来自 H5 包的通知').then(function(){out('已发送通知')}).catch(out)}
      function runCmd(){velum.exec('uname -a').then(out).catch(out)}
    </script>
    </body></html>
    """

    /// 形态 1 演示：H5 界面经桥调用 iSH CLI/ELF。
    private static let elfDemoHTML = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>ELF 桥接演示</title>
    <style>
      body{font-family:-apple-system,sans-serif;background:#0b0e14;color:#e6e6e6;padding:24px}
      h1{font-size:20px} input{width:70%;padding:10px;border-radius:10px;border:0;background:#161b26;color:#e6e6e6}
      button{padding:10px 16px;border-radius:10px;border:0;background:#22c55e;color:#04210f;font-size:15px}
      pre{background:#161b26;padding:12px;border-radius:10px;white-space:pre-wrap;word-break:break-all}
    </style></head><body>
    <h1>形态 1 · ELF 桥接</h1>
    <p>H5 界面 ↔ iSH 内 Linux CLI/ELF。输入命令，经 velum.exec 在 Container 内执行。</p>
    <input id="cmd" value="ls -la /etc | head" />
    <button onclick="run()">执行</button>
    <pre id="out">输出会显示在这里</pre>
    <script>
      function out(t){document.getElementById('out').textContent=t}
      function run(){var c=document.getElementById('cmd').value;out('执行中…');velum.exec(c).then(out).catch(out)}
    </script>
    </body></html>
    """
}
