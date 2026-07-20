//
//  PreviewRendererView.swift
//  Velum
//
//  Type-dispatched renderer for the universal Previewer.
//  Switches on PreviewerViewModel.PreviewType and renders the matching view:
//    pdf        → PDFKit
//    html       → WKWebView (remote URL or inline HTML)
//    markdown   → minimal CommonMark → HTML converter, rendered in WKWebView
//    image      → SwiftUI Image from Data
//    video      → AVKit VideoPlayer
//    audio      → AVAudioPlayer with custom controls
//    office     → QuickLook (QLPreviewController) for pptx/docx/xlsx/...
//    text       → monospaced ScrollView
//

import SwiftUI
import PDFKit
import AVKit
import AVFoundation
import WebKit
import QuickLook

// MARK: - Renderer dispatch

struct PreviewRendererView: View {
    let state: PreviewerViewModel.PreviewState

    var body: some View {
        switch state {
        case .empty:
            emptyState
        case .loading(let message):
            VStack(spacing: 12) {
                ProgressView()
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            errorState(message)
        case .loaded(let content):
            renderer(for: content)
        }
    }

    @ViewBuilder
    private func renderer(for content: PreviewerViewModel.PreviewContent) -> some View {
        switch content.type {
        case .pdf:
            if let data = content.data {
                PDFRenderer(data: data)
            } else {
                errorState("PDF 数据为空")
            }
        case .html:
            HTMLRenderer(remoteURL: content.remoteURL, data: content.data)
        case .markdown:
            if let data = content.data {
                MarkdownRenderer(data: data)
            } else {
                errorState("Markdown 数据为空")
            }
        case .image:
            if let data = content.data {
                ImageRenderer(data: data)
            } else {
                errorState("无法解码图片")
            }
        case .video:
            if let url = content.fileURL ?? content.remoteURL {
                VideoRenderer(url: url)
            } else {
                errorState("无视频源")
            }
        case .audio:
            if let url = content.fileURL ?? content.remoteURL {
                AudioRenderer(url: url)
            } else {
                errorState("无音频源")
            }
        case .office:
            if let url = content.fileURL {
                OfficeRenderer(url: url)
            } else {
                errorState("无法预览此文档")
            }
        case .text:
            if let data = content.data {
                TextRenderer(data: data)
            } else {
                errorState("无法读取文本")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("输入地址或从侧边栏选择文件以预览")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("支持 PDF · 图片 · 视频 · 音频 · Markdown · HTML · Office 文档")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - PDF (PDFKit)

struct PDFRenderer: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.backgroundColor = .clear
        pdfView.document = PDFDocument(data: data)
        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}
}

// MARK: - Image

struct ImageRenderer: View {
    let data: Data

    var body: some View {
        if let uiImage = UIImage(data: data) {
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
            }
            .background(Color.black.opacity(0.2))
        } else {
            Text("无法解码图片数据")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Video (AVKit)

struct VideoRenderer: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player = player {
                VideoPlayer(player: player)
            } else {
                ProgressView("加载视频…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            let p = AVPlayer(url: url)
            self.player = p
            p.play()
        }
        .onDisappear {
            player?.pause()
        }
    }
}

// MARK: - Audio (AVAudioPlayer + custom controls)

@MainActor
private final class AudioController: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var seekFraction: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(url: URL) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Audio session setup failure is non-fatal.
        }
        do {
            player = try AVAudioPlayer(contentsOf: url)
            duration = player?.duration ?? 0
            player?.prepareToPlay()
        } catch {
            // Decoding failed — leave player nil, UI shows idle state.
        }
    }

    func toggle() {
        guard let player = player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            timer?.invalidate()
        } else {
            player.play()
            isPlaying = true
            startTimer()
        }
    }

    func seek() {
        guard let player = player else { return }
        player.currentTime = seekFraction * duration
        currentTime = player.currentTime
    }

    func skip(_ seconds: Double) {
        guard let player = player else { return }
        player.currentTime = max(0, min(duration, player.currentTime + seconds))
        currentTime = player.currentTime
        seekFraction = duration > 0 ? currentTime / duration : 0
    }

    func stop() {
        timer?.invalidate()
        player?.stop()
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let p = self.player else { return }
                self.currentTime = p.currentTime
                self.seekFraction = self.duration > 0 ? p.currentTime / self.duration : 0
                if !p.isPlaying && self.isPlaying {
                    self.isPlaying = false
                    self.timer?.invalidate()
                }
            }
        }
    }
}

struct AudioRenderer: View {
    let url: URL
    @StateObject private var controller = AudioController()

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            audioWaveformIcon

            Text(url.lastPathComponent)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            VStack(spacing: 6) {
                Slider(value: $controller.seekFraction, in: 0...1) { editing in
                    if !editing { controller.seek() }
                }
                HStack {
                    Text(formatTime(controller.currentTime))
                    Spacer()
                    Text(formatTime(controller.duration))
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 420)

            HStack(spacing: 48) {
                Button { controller.skip(-15) } label: {
                    Image(systemName: "gobackward.15").font(.title)
                }
                Button { controller.toggle() } label: {
                    Image(systemName: controller.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 56))
                }
                Button { controller.skip(15) } label: {
                    Image(systemName: "goforward.15").font(.title)
                }
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { controller.load(url: url) }
        .onDisappear { controller.stop() }
    }

    private func formatTime(_ t: Double) -> String {
        guard t.isFinite, !t.isNaN else { return "0:00" }
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 波形图标 — iOS 17+ 才支持 .symbolEffect，旧系统回退为静态图标。
    @ViewBuilder
    private var audioWaveformIcon: some View {
        let base = Image(systemName: "waveform.circle.fill")
            .font(.system(size: 96))
            .foregroundStyle(.tint)
        if #available(iOS 17.0, *) {
            base.symbolEffect(.variableColor, isActive: controller.isPlaying)
        } else {
            base.opacity(controller.isPlaying ? 1.0 : 0.5)
        }
    }
}

// MARK: - HTML (WKWebView)

struct HTMLRenderer: UIViewRepresentable {
    let remoteURL: URL?
    let data: Data?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        if #available(iOS 16.4, *) {
            config.defaultWebpagePreferences.preferredContentMode = .mobile
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.indicatorStyle = .white
        webView.allowsBackForwardNavigationGestures = true

        if let url = remoteURL {
            webView.load(URLRequest(url: url))
        } else if let data = data, let html = String(data: data, encoding: .utf8) {
            webView.loadHTMLString(html, baseURL: nil)
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - Markdown (convert → styled HTML → WKWebView)

struct MarkdownRenderer: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.indicatorStyle = .white

        let md = String(data: data, encoding: .utf8) ?? ""
        let body = MarkdownConverter.toHTML(md)
        let html = MarkdownConverter.pageTemplate(content: body, title: nil)
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - Office (QuickLook)

struct OfficeRenderer: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiController: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            return url as NSURL
        }
    }
}

// MARK: - Text (monospaced ScrollView)

struct TextRenderer: View {
    let data: Data

    var body: some View {
        let text = String(data: data, encoding: .utf8) ?? "(二进制内容，无法以 UTF-8 显示)"
        ScrollView {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(16)
        }
    }
}

// MARK: - Minimal Markdown → HTML converter
//
// A compact, dependency-free converter covering the common subset:
// code blocks, headings, horizontal rules, blockquotes, ordered/unordered
// lists, paragraphs, and inline transforms (bold / italic / inline code /
// links / images / strikethrough). Good enough for most .md files offline.

enum MarkdownConverter {

    static func pageTemplate(content: String, title: String?) -> String {
        let titleTag = title.map { "<title>\(escapeHTML($0))</title>" } ?? ""
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        \(titleTag)
        <style>
          :root { color-scheme: dark; }
          body {
            font-family: -apple-system, "PingFang SC", "Helvetica Neue", sans-serif;
            color: #e6e6e6; background: transparent;
            line-height: 1.6; max-width: 720px; margin: 0 auto; padding: 20px 16px 48px;
            -webkit-text-size-adjust: 100%;
          }
          h1,h2,h3,h4,h5,h6 { font-weight: 700; margin: 1.2em 0 0.5em; line-height: 1.3; }
          h1 { font-size: 1.8em; border-bottom: 1px solid rgba(255,255,255,0.15); padding-bottom: .3em; }
          h2 { font-size: 1.5em; border-bottom: 1px solid rgba(255,255,255,0.12); padding-bottom: .3em; }
          h3 { font-size: 1.25em; }
          h4 { font-size: 1.05em; }
          p { margin: .6em 0; }
          a { color: #5ab0ff; text-decoration: none; }
          a:active { color: #7fc4ff; }
          code {
            font-family: ui-monospace, "SF Mono", SFMono-Regular, Menlo, monospace;
            background: rgba(255,255,255,0.10); padding: 2px 5px; border-radius: 5px;
            font-size: 0.88em;
          }
          pre {
            background: rgba(0,0,0,0.35); padding: 14px 16px; border-radius: 10px;
            overflow-x: auto; -webkit-overflow-scrolling: touch;
          }
          pre code { background: transparent; padding: 0; font-size: 0.85em; }
          blockquote {
            border-left: 3px solid rgba(255,255,255,0.3);
            margin: .6em 0; padding: .2em 1em; color: #b5b5b5;
          }
          ul,ol { padding-left: 1.6em; margin: .6em 0; }
          li { margin: .2em 0; }
          hr { border: none; border-top: 1px solid rgba(255,255,255,0.2); margin: 1.4em 0; }
          img { max-width: 100%; border-radius: 8px; }
          table { border-collapse: collapse; margin: .8em 0; display: block; overflow-x: auto; }
          td,th { border: 1px solid rgba(255,255,255,0.2); padding: 6px 12px; }
          th { background: rgba(255,255,255,0.06); }
          del { color: #999; }
        </style>
        </head>
        <body>
        \(content)
        </body>
        </html>
        """
    }

    static func toHTML(_ markdown: String) -> String {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var out: [String] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // Fenced code block
            if line.hasPrefix("```") {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 } // closing fence
                let langClass = lang.isEmpty ? "" : " class=\"language-\(escapeHTML(lang))\""
                out.append("<pre><code\(langClass)>\(escapeHTML(code.joined(separator: "\n")))</code></pre>")
                continue
            }

            // Heading
            if let (level, text) = parseHeading(line) {
                out.append("<h\(level)>\(inline(text))</h\(level)>")
                i += 1
                continue
            }

            // Horizontal rule
            if isHorizontalRule(line) {
                out.append("<hr/>")
                i += 1
                continue
            }

            // Blockquote
            if line.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                var quote: [String] = []
                while i < lines.count {
                    let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix(">") else { break }
                    quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                out.append("<blockquote>\(inline(quote.joined(separator: " ")))</blockquote>")
                continue
            }

            // Unordered list
            if isUnorderedItem(line) {
                out.append("<ul>")
                while i < lines.count && isUnorderedItem(lines[i]) {
                    let content = listContent(lines[i])
                    out.append("<li>\(inline(content))</li>")
                    i += 1
                }
                out.append("</ul>")
                continue
            }

            // Ordered list
            if isOrderedItem(line) {
                out.append("<ol>")
                while i < lines.count && isOrderedItem(lines[i]) {
                    let content = listContent(lines[i])
                    out.append("<li>\(inline(content))</li>")
                    i += 1
                }
                out.append("</ol>")
                continue
            }

            // Blank line
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
                continue
            }

            // Paragraph (gather consecutive non-structural lines)
            var para: [String] = [line]
            i += 1
            while i < lines.count {
                let next = lines[i]
                if next.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if next.hasPrefix("#") || next.hasPrefix("```") { break }
                if next.trimmingCharacters(in: .whitespaces).hasPrefix(">") { break }
                if isHorizontalRule(next) || isUnorderedItem(next) || isOrderedItem(next) { break }
                para.append(next.trimmingCharacters(in: .whitespaces))
                i += 1
            }
            out.append("<p>\(inline(para.joined(separator: " ")))</p>")
        }

        return out.joined(separator: "\n")
    }

    // MARK: Inline

    static func inline(_ text: String) -> String {
        var s = escapeHTML(text)
        // Images: ![alt](url)
        s = replace(s, pattern: #"!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#) { m, str in
            let alt = str.substring(with: m.range(at: 1))
            let url = str.substring(with: m.range(at: 2))
            return "<img src=\"\(url)\" alt=\"\(alt)\"/>"
        }
        // Links: [text](url)
        s = replace(s, pattern: #"\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#) { m, str in
            let txt = str.substring(with: m.range(at: 1))
            let url = str.substring(with: m.range(at: 2))
            return "<a href=\"\(url)\">\(txt)</a>"
        }
        // Inline code — extract first to avoid nested transforms.
        s = replace(s, pattern: #"`([^`]+)`"#) { m, str in
            let code = str.substring(with: m.range(at: 1))
            return "<code>\(code)</code>"
        }
        // Bold
        s = replace(s, pattern: #"\*\*([^*]+)\*\*"#) { m, str in
            "<strong>\(str.substring(with: m.range(at: 1)))</strong>"
        }
        s = replace(s, pattern: #"__([^_]+)__"#) { m, str in
            "<strong>\(str.substring(with: m.range(at: 1)))</strong>"
        }
        // Strikethrough
        s = replace(s, pattern: #"~~([^~]+)~~"#) { m, str in
            "<del>\(str.substring(with: m.range(at: 1)))</del>"
        }
        // Italic
        s = replace(s, pattern: #"\*([^*]+)\*"#) { m, str in
            "<em>\(str.substring(with: m.range(at: 1)))</em>"
        }
        s = replace(s, pattern: #"(?<!\w)_([^_]+)_(?!\w)"#) { m, str in
            "<em>\(str.substring(with: m.range(at: 1)))</em>"
        }
        return s
    }

    // MARK: Helpers

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func parseHeading(_ line: String) -> (Int, String)? {
        var n = 0
        for ch in line {
            if ch == "#" { n += 1 } else { break }
        }
        guard n >= 1, n <= 6, line.count > n else { return nil }
        let after = line.dropFirst(n)
        guard after.first == " " else { return nil }
        let text = String(after.dropFirst()).trimmingCharacters(in: .whitespaces)
        return (n, text)
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        let ch = trimmed.first
        return (ch == "-" || ch == "*" || ch == "_")
            && Set(trimmed).count == 1
            && trimmed.count >= 3
    }

    private static func isUnorderedItem(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return false }
        guard first == "-" || first == "*" || first == "+" else { return false }
        return trimmed.count >= 2 && trimmed[trimmed.index(after: trimmed.startIndex)] == " "
    }

    private static func isOrderedItem(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let dotIndex = trimmed.firstIndex(of: ".") else { return false }
        let prefix = trimmed[..<dotIndex]
        guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber) else { return false }
        let after = trimmed[trimmed.index(after: dotIndex)...]
        return after.first == " "
    }

    private static func listContent(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let first = trimmed.first,
           (first == "-" || first == "*" || first == "+") {
            return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        if let dotIndex = trimmed.firstIndex(of: ".") {
            return String(trimmed[trimmed.index(after: dotIndex)...])
                .trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    private static func replace(
        _ string: String,
        pattern: String,
        build: (NSTextCheckingResult, NSString) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return string
        }
        let nsString = string as NSString
        let matches = regex.matches(
            in: string,
            options: [],
            range: NSRange(location: 0, length: nsString.length)
        )
        if matches.isEmpty { return string }

        var result = ""
        var cursor = 0
        for match in matches {
            let r = match.range
            if r.location > cursor {
                result += nsString.substring(with: NSRange(location: cursor, length: r.location - cursor))
            }
            result += build(match, nsString)
            cursor = r.location + r.length
        }
        if cursor < nsString.length {
            result += nsString.substring(from: cursor)
        }
        return result
    }
}
