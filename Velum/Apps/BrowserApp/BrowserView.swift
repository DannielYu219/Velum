//
//  BrowserView.swift
//  Velum
//
//  内置浏览器 App — 基于 WKWebView，支持最新 Web 特性、允许不安全连接。
//  支持多标签页管理。
//

import SwiftUI
import WebKit

// MARK: - BrowserTab (per-tab state)

@MainActor
final class BrowserTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published var addressText: String = ""
    @Published var currentURL: URL?
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var estimatedProgress: Double = -1
    @Published var isLoading: Bool = false
    @Published var pageTitle: String = ""
    weak var webView: WKWebView?

    func load(_ url: URL) {
        var req = URLRequest(url: url)
        req.cachePolicy = .useProtocolCachePolicy
        webView?.load(req)
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func stopLoading() { webView?.stopLoading() }
}

// MARK: - BrowserViewModel (global state)

@MainActor
final class BrowserViewModel: ObservableObject {

    @Published var tabs: [BrowserTab] = []
    @Published var selectedTabIndex: Int = 0

    @Published var desktopMode: Bool = false
    @Published var allowInsecure: Bool = true

    let homeURL: URL = URL(string: "https://www.bing.com")!

    var selectedTab: BrowserTab? {
        guard selectedTabIndex >= 0, selectedTabIndex < tabs.count else { return nil }
        return tabs[selectedTabIndex]
    }

    init() {
        addTab()
    }

    func addTab() {
        let tab = BrowserTab()
        tabs.append(tab)
        selectedTabIndex = tabs.count - 1
    }

    func closeTab(_ tab: BrowserTab) {
        guard tabs.count > 1 else { return }
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: idx)
        if selectedTabIndex >= tabs.count {
            selectedTabIndex = tabs.count - 1
        } else if selectedTabIndex > idx {
            selectedTabIndex -= 1
        }
    }

    func selectTab(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }
        selectedTabIndex = index
    }

    func normalizeURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        if trimmed.contains("."), !trimmed.contains(" ") {
            return URL(string: "https://" + trimmed)
        }
        let encoded = trimmed.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? trimmed
        return URL(string: "https://www.bing.com/search?q=\(encoded)")
    }

    /// 代理方法：当前标签页
    func goBack() { selectedTab?.goBack() }
    func goForward() { selectedTab?.goForward() }
    func reload() { selectedTab?.reload() }
    func stopLoading() { selectedTab?.stopLoading() }
    func loadHome() {
        guard let tab = selectedTab else { return }
        tab.load(homeURL)
        tab.addressText = homeURL.absoluteString
    }

    func loadIfNeeded() {
        guard let tab = selectedTab else { return }
        guard let url = normalizeURL(tab.addressText) else { return }
        tab.load(url)
    }

    func toggleDesktopMode() {
        desktopMode.toggle()
        applyUserAgent()
        for tab in tabs { tab.reload() }
    }

    func applyUserAgent() {
        let chromeDesktop = [
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
            "AppleWebKit/537.36 (KHTML, like Gecko)",
            "Chrome/131.0.0.0 Safari/537.36"
        ].joined(separator: " ")

        let chromeMobile = [
            "Mozilla/5.0 (Linux; Android 14; Pixel 8 Pro)",
            "AppleWebKit/537.36 (KHTML, like Gecko)",
            "Chrome/131.0.6778.200 Mobile Safari/537.36"
        ].joined(separator: " ")

        for tab in tabs {
            guard let webView = tab.webView else { continue }
            webView.customUserAgent = desktopMode ? chromeDesktop : chromeMobile
            if #available(iOS 16.4, *) {
                webView.configuration.defaultWebpagePreferences.preferredContentMode =
                    desktopMode ? .desktop : .mobile
            }
        }
    }
}

// MARK: - Browser Trinity Button

private struct BrowserTrinityButton: View {
    let tint: Color
    let symbol: String
    let action: () -> Void

    var body: some View {
        ZStack {
            Image(systemName: symbol)
                .imageScale(.large)
                .symbolRenderingMode(.monochrome)
                .font(.system(.footnote, weight: .black))
                .foregroundStyle(tint)
        }
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

// MARK: - BrowserView

struct BrowserView: View {
    let onClose: () -> Void
    let onMinimize: () -> Void
    let onZoom: () -> Void
    let onFocus: () -> Void
    let onDrag: (CGPoint) -> Void
    let isMaximized: Bool

    @StateObject private var vm = BrowserViewModel()
    @State private var showSettings: Bool = false
    @State private var dragOrigin: CGPoint?
    @State private var localPosition: CGPoint

    init(
        onClose: @escaping () -> Void = {},
        onMinimize: @escaping () -> Void = {},
        onZoom: @escaping () -> Void = {},
        onFocus: @escaping () -> Void = {},
        onDrag: @escaping (CGPoint) -> Void = { _ in },
        isMaximized: Bool = false,
        position: CGPoint = .zero
    ) {
        self.onClose = onClose
        self.onMinimize = onMinimize
        self.onZoom = onZoom
        self.onFocus = onFocus
        self.onDrag = onDrag
        self.isMaximized = isMaximized
        _localPosition = State(initialValue: position)
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            progressBar
            tabBar
            Divider().background(Color.white.opacity(0.1))
            content
        }
        .background(Color.clear)
        .sheet(isPresented: $showSettings) {
            BrowserSettingsSheet(vm: vm)
                .presentationDetents([.medium])
        }
    }

    // MARK: - Title Bar

    @ViewBuilder
    private var titleBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                BrowserTrinityButton(tint: .red, symbol: "xmark", action: onClose)
                    .padding(.trailing, 4)
                BrowserTrinityButton(tint: .yellow, symbol: "minus", action: onMinimize)
                    .padding(.horizontal, 4)
                BrowserTrinityButton(tint: .green, symbol: "square", action: onZoom)
                    .padding(.leading, 4)
            }
            .padding(.trailing, 8)

            browserButton(systemName: "chevron.left",
                          isEnabled: vm.selectedTab?.canGoBack ?? false) { vm.goBack() }
            browserButton(systemName: "chevron.right",
                          isEnabled: vm.selectedTab?.canGoForward ?? false) { vm.goForward() }

            HStack(spacing: 6) {
                Image(systemName: securityIcon)
                    .imageScale(.small)
                    .foregroundStyle(securityColor)
                    .frame(width: 14)

                TextField("搜索或输入网址", text: Binding(
                    get: { vm.selectedTab?.addressText ?? "" },
                    set: { vm.selectedTab?.addressText = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(.body, design: .default))
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
                .submitLabel(.go)
                .onSubmit { vm.loadIfNeeded() }

                if !(vm.selectedTab?.addressText ?? "").isEmpty {
                    Button {
                        vm.selectedTab?.addressText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .imageScale(.small)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule(style: .continuous))
            .padding(.horizontal, 6)
            .frame(minWidth: 120)

            browserButton(systemName: "plus", isEnabled: true) { vm.addTab() }
            browserButton(systemName: vm.selectedTab?.isLoading ?? false ? "xmark" : "arrow.clockwise",
                          isEnabled: true) {
                if vm.selectedTab?.isLoading ?? false { vm.stopLoading() }
                else { vm.reload() }
            }
            browserButton(systemName: "gearshape.fill", isEnabled: true) { showSettings = true }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if !isMaximized {
                        if dragOrigin == nil {
                            dragOrigin = localPosition
                        }
                        localPosition = CGPoint(
                            x: dragOrigin!.x + value.translation.width,
                            y: dragOrigin!.y + value.translation.height
                        )
                    }
                }
                .onEnded { _ in
                    onDrag(localPosition)
                    dragOrigin = nil
                }
        )
    }

    @ViewBuilder
    private func browserButton(
        systemName: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .imageScale(.medium)
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.4))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private var securityIcon: String {
        guard let url = vm.selectedTab?.currentURL else { return "magnifyingglass" }
        if url.scheme == "https" { return "lock.fill" }
        if url.scheme == "http" { return "lock.open.fill" }
        if url.isFileURL { return "doc.fill" }
        return "globe"
    }

    private var securityColor: Color {
        guard let url = vm.selectedTab?.currentURL else { return .secondary }
        if url.scheme == "https" { return .green }
        if url.scheme == "http" { return .orange }
        return .secondary
    }

    // MARK: - Progress bar

    @ViewBuilder
    private var progressBar: some View {
        if let tab = vm.selectedTab, tab.isLoading, tab.estimatedProgress >= 0 {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.05))
                        .frame(height: 2)
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(
                            width: geo.size.width * tab.estimatedProgress,
                            height: 2
                        )
                        .animation(.easeInOut(duration: 0.2), value: tab.estimatedProgress)
                }
            }
            .frame(height: 2)
        }
    }

    // MARK: - Tab Bar

    @ViewBuilder
    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(vm.tabs.enumerated()), id: \.element.id) { index, tab in
                    TabChip(
                        title: tabLabel(tab),
                        isSelected: index == vm.selectedTabIndex,
                        isLoading: tab.isLoading,
                        onSelect: { vm.selectTab(index) },
                        onClose: { vm.closeTab(tab) },
                        canClose: vm.tabs.count > 1
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(height: 34)
        .background(Color.black.opacity(0.15))
    }

    private func tabLabel(_ tab: BrowserTab) -> String {
        if !tab.pageTitle.isEmpty { return tab.pageTitle }
        if let host = tab.currentURL?.host { return host }
        return "新标签页"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ZStack {
            ForEach(vm.tabs) { tab in
                BrowserWebView(tab: tab, vm: vm)
                    .opacity(tab.id == vm.selectedTab?.id ? 1 : 0)
                    .allowsHitTesting(tab.id == vm.selectedTab?.id)
            }
        }
    }
}

// MARK: - Tab Chip

private struct TabChip: View {
    let title: String
    let isSelected: Bool
    let isLoading: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let canClose: Bool

    var body: some View {
        HStack(spacing: 4) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            }
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(maxWidth: 140)

            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - Settings Sheet

private struct BrowserSettingsSheet: View {
    @ObservedObject var vm: BrowserViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("浏览") {
                    Toggle("桌面模式", isOn: Binding(
                        get: { vm.desktopMode },
                        set: { newValue in
                            if newValue != vm.desktopMode {
                                vm.toggleDesktopMode()
                            }
                        }
                    ))
                    Toggle("允许不安全连接", isOn: $vm.allowInsecure)
                }
                .listRowBackground(Color.clear)

                Section("关于") {
                    HStack {
                        Text("引擎")
                        Spacer()
                        Text("WKWebView")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("标签页数")
                        Spacer()
                        Text("\(vm.tabs.count)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Inspector")
                        Spacer()
                        Text(inspectorAvailable ? "已启用" : "不可用")
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .navigationTitle("浏览器设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var inspectorAvailable: Bool {
        guard let webView = vm.selectedTab?.webView else { return false }
        if #available(iOS 16.4, *) { return webView.isInspectable }
        return false
    }
}

// MARK: - BrowserWebView (UIViewRepresentable)

struct BrowserWebView: UIViewRepresentable {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var vm: BrowserViewModel

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        let preferences = WKPreferences()
        preferences.javaScriptEnabled = true
        preferences.javaScriptCanOpenWindowsAutomatically = true
        if #available(iOS 14.5, *) {
            preferences.isTextInteractionEnabled = true
        }
        config.preferences = preferences

        if #available(iOS 16.4, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = true
            config.defaultWebpagePreferences.preferredContentMode = .mobile
        }

        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")

        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsInlineMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.websiteDataStore = WKWebsiteDataStore.default()

        if #available(iOS 17.0, *) {
            config.preferences.isElementFullscreenEnabled = true
        }

        let webView = WKWebView(frame: .zero, configuration: config)

        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }

        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.indicatorStyle = .white
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.scrollView.minimumZoomScale = 0.25
        webView.scrollView.maximumZoomScale = 5.0
        webView.scrollView.isScrollEnabled = true

        tab.webView = webView

        let coordinator = context.coordinator
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        coordinator.observeProgress(webView)

        vm.applyUserAgent()
        tab.load(vm.homeURL)
        tab.addressText = vm.homeURL.absoluteString

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if #available(iOS 16.4, *) {
            uiView.isInspectable = true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(tab: tab, vm: vm)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private weak var tab: BrowserTab?
        private weak var vm: BrowserViewModel?
        private var progressObserver: NSKeyValueObservation?
        private var titleObserver: NSKeyValueObservation?
        private var canGoBackObserver: NSKeyValueObservation?
        private var canGoForwardObserver: NSKeyValueObservation?
        private var urlObserver: NSKeyValueObservation?
        private var loadingObserver: NSKeyValueObservation?

        init(tab: BrowserTab, vm: BrowserViewModel) {
            self.tab = tab
            self.vm = vm
            super.init()
        }

        func observeProgress(_ webView: WKWebView) {
            progressObserver = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, change in
                guard let self else { return }
                Task { @MainActor in
                    self.tab?.estimatedProgress = change.newValue ?? 0
                }
            }
            titleObserver = webView.observe(\.title, options: [.new]) { [weak self] _, change in
                guard let self else { return }
                Task { @MainActor in
                    if let title = change.newValue.flatMap({ $0 }) {
                        self.tab?.pageTitle = title
                    }
                }
            }
            canGoBackObserver = webView.observe(\.canGoBack, options: [.new]) { [weak self] _, change in
                guard let self else { return }
                Task { @MainActor in
                    self.tab?.canGoBack = change.newValue ?? false
                }
            }
            canGoForwardObserver = webView.observe(\.canGoForward, options: [.new]) { [weak self] _, change in
                guard let self else { return }
                Task { @MainActor in
                    self.tab?.canGoForward = change.newValue ?? false
                }
            }
            urlObserver = webView.observe(\.url, options: [.new]) { [weak self] _, change in
                guard let self else { return }
                Task { @MainActor in
                    let url = change.newValue ?? nil
                    self.tab?.currentURL = url
                    if let url = url, self.tab?.addressText != url.absoluteString {
                        self.tab?.addressText = url.absoluteString
                    }
                }
            }
            loadingObserver = webView.observe(\.isLoading, options: [.new]) { [weak self] _, change in
                guard let self else { return }
                Task { @MainActor in
                    self.tab?.isLoading = change.newValue ?? false
                    if !(change.newValue ?? false) {
                        self.tab?.estimatedProgress = -1
                    }
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard let vm = vm else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            if !vm.allowInsecure {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            let method = challenge.protectionSpace.authenticationMethod
            if method == NSURLAuthenticationMethodServerTrust {
                if let trust = challenge.protectionSpace.serverTrust {
                    let credential = URLCredential(trust: trust)
                    completionHandler(.useCredential, credential)
                } else {
                    completionHandler(.performDefaultHandling, nil)
                }
            } else if method == NSURLAuthenticationMethodHTTPBasic ||
                      method == NSURLAuthenticationMethodHTTPDigest {
                completionHandler(.performDefaultHandling, nil)
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        // MARK: WKUIDelegate

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            presentAlert(title: "JavaScript", message: message,
                         buttons: [("确定", .default)],
                         completionHandler: { _ in completionHandler() })
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            presentAlert(title: "确认", message: message,
                         buttons: [("取消", .cancel), ("确定", .default)],
                         completionHandler: { idx in completionHandler(idx == 1) })
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            presentTextInput(title: prompt, defaultText: defaultText,
                             completionHandler: completionHandler)
        }

        private func presentAlert(
            title: String, message: String,
            buttons: [(String, UIAlertAction.Style)],
            completionHandler: @escaping (Int) -> Void
        ) {
            Task { @MainActor in
                guard let vc = topViewController() else { completionHandler(0); return }
                let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
                for (i, (text, style)) in buttons.enumerated() {
                    alert.addAction(UIAlertAction(title: text, style: style) { _ in completionHandler(i) })
                }
                vc.present(alert, animated: true)
            }
        }

        private func presentTextInput(
            title: String, defaultText: String?,
            completionHandler: @escaping (String?) -> Void
        ) {
            Task { @MainActor in
                guard let vc = topViewController() else { completionHandler(nil); return }
                let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
                alert.addTextField { tf in tf.text = defaultText }
                alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
                alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
                    completionHandler(alert.textFields?.first?.text)
                })
                vc.present(alert, animated: true)
            }
        }

        @MainActor
        private func topViewController() -> UIViewController? {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
                  let window = scene.windows.first(where: { $0.isKeyWindow }),
                  var top = window.rootViewController else { return nil }
            while let presented = top.presentedViewController { top = presented }
            return top
        }
    }
}

#Preview {
    BrowserView(onClose: {}, onMinimize: {}, onZoom: {}, onFocus: {})
        .preferredColorScheme(.dark)
}
