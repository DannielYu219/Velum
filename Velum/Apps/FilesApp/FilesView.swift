//
//  FilesView.swift
//  Velum
//
//  Phase 3.4: SwiftUI Files App — browse iSH fakefs via ISHBridge.
//
//  Features:
//  - 顶部工具栏：后退 / 前进 / 上一级 + 可编辑地址栏 + 刷新
//  - 列表过滤掉 . 与 ..（改由工具栏按钮承载"上一级"功能）
//  - 目录优先、文件名字母序
//  - 点击目录 → 进入；双击或回车 → 进入输入的路径
//  - 长按文件 → 上下文菜单（Open in Terminal / Copy Path / Delete）
//  - 行支持拖拽到桌面（提供 fakefs 绝对路径字符串）
//  - 加载 / 错误 / 空目录状态
//  - 历史栈：前进 / 后退
//
//  Data source: ISHBridge.shared.listDir
//

import SwiftUI

struct FilesView: View {
    @State private var path: String
    @State private var entries: [ISHDirEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    /// 地址栏当前编辑文本（与 `path` 分离，便于在输入过程中保留光标位置）。
    @State private var addressText: String = "/"
    @State private var isEditingAddress: Bool = false

    /// 历史栈与当前位置。
    @State private var history: [String] = ["/"]
    @State private var historyIndex: Int = 0

    private let bridge = ISHBridge.shared

    init(initialPath: String = "/") {
        let p = FilesView.normalize(initialPath)
        _path = State(initialValue: p)
        _addressText = State(initialValue: p)
        _history = State(initialValue: [p])
        _historyIndex = State(initialValue: 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().background(Color.white.opacity(0.1))
            content
        }
        .background(Color.clear)
        .task(id: path) {
            await load()
        }
    }

    // MARK: - Toolbar（后退 / 前进 / 上一级 + 地址栏 + 刷新）

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 8) {
            // 可编辑地址栏（共享组件）
            ChromeAddressField(
                placeholder: "输入路径，如 /root",
                text: $addressText,
                leadingIcon: "folder.fill",
                leadingIconColor: .secondary,
                onSubmit: { commitAddress() }
            )
            .onChange(of: path) { newPath in
                if !isEditingAddress {
                    addressText = newPath
                }
            }

            // 刷新（等价于点击 "." 目录）
            ChromeToolButton(systemName: "arrow.clockwise") {
                Task { await load() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Loading \(path)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { await load() }
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            // 路径不存在 → listDir 会抛错；此处表示"目录存在但为空"
            VStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("空目录")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(sortedEntries) { entry in
                    row(for: entry)
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Color.white.opacity(0.1))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
    }

    private var sortedEntries: [ISHDirEntry] {
        // 保留 . 和 .. —— 它们点击有效，由 fakefs 解析路径语义。
        // . = 刷新当前目录；.. = 上一级。
        entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    @ViewBuilder
    private func row(for entry: ISHDirEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                .imageScale(.large)
                .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(entry.permissionString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(entry.formattedSize)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // 双击：目录 → 进入；文件 → 在查看窗口中打开
            if entry.isDirectory {
                navigateInto(entry.name)
            } else if entry.isRegularFile {
                openInViewer(entry)
            }
        }
        .onTapGesture(count: 1) {
            if entry.isDirectory {
                navigateInto(entry.name)
            }
        }
        // 支持拖拽到桌面：以 fakefs 完整路径作为 NSItemProvider
        .onDrag {
            let full = fullPath(for: entry)
            return NSItemProvider(object: full as NSString)
        }
        .contextMenu {
            if entry.isRegularFile {
                Button {
                    openInViewer(entry)
                } label: {
                    Label("在查看窗口中打开", systemImage: "doc.text.fill")
                }
                Button {
                    openInPreviewer(entry)
                } label: {
                    Label("在预览 App 中打开", systemImage: "eye.fill")
                }
            }
            Button {
                copyPath(for: entry)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
            if entry.isRegularFile {
                Button {
                    openInTerminal(entry)
                } label: {
                    Label("Open in Terminal", systemImage: "terminal")
                }
            }
            if entry.name != "." && entry.name != ".." {
                Button(role: .destructive) {
                    deleteEntry(entry)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let raw = try await bridge.listDir(path)
            entries = raw
        } catch {
            // 路径不存在 / 不可读 → 显示空（错误信息不暴露给用户长栈）
            entries = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
        if !isEditingAddress {
            addressText = path
        }
    }

    // MARK: - Navigation

    private func commitAddress() {
        let p = FilesView.normalize(addressText)
        isEditingAddress = false
        navigate(to: p)
    }

    private func navigateInto(_ name: String) {
        // 直接拼接路径，由 fakefs 的 listDir 解析 . 和 .. 语义。
        // 不做 normalize / guard —— 原来就是这么做的，点击 . 和 .. 都有效。
        let next = path == "/" ? "/\(name)" : "\(path)/\(name)"
        path = next
        addressText = next
    }

    private func navigateUp() {
        // 不用字符串切割算父路径 —— 直接进入 ".." 目录，
        // 由 fakefs 的 openat/listDir 负责解析 `..` 语义。
        // 这与点击原列表里的 ".." 文件夹完全等价。
        guard path != "/" else { return }
        navigateInto("..")
    }

    private func navigate(to target: String) {
        let p = FilesView.normalize(target)
        guard p != path else { return }
        // 截断"前进"历史
        if historyIndex < history.count - 1 {
            history = Array(history.prefix(historyIndex + 1))
        }
        history.append(p)
        historyIndex = history.count - 1
        path = p
        addressText = p
    }

    private func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        let p = history[historyIndex]
        path = p
        addressText = p
        isEditingAddress = false
    }

    private func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        let p = history[historyIndex]
        path = p
        addressText = p
        isEditingAddress = false
    }

    private var canGoBack: Bool { historyIndex > 0 }
    private var canGoForward: Bool { historyIndex < history.count - 1 }

    /// 计算当前目录下条目的 fakefs 绝对路径。
    private func fullPath(for entry: ISHDirEntry) -> String {
        path == "/" ? "/\(entry.name)" : "\(path)/\(entry.name)"
    }

    private func copyPath(for entry: ISHDirEntry) {
        UIPasteboard.general.string = fullPath(for: entry)
    }

    private func openInTerminal(_ entry: ISHDirEntry) {
        VelumControl.shared.perform(.openInTerminal(fullPath(for: entry)))
    }

    /// 在专用文件查看窗口中打开（无侧边栏，仅显示文件内容）。
    private func openInViewer(_ entry: ISHDirEntry) {
        WindowManager.shared.open(.viewer, contextPath: fullPath(for: entry))
    }

    /// 在预览 App 中打开（带侧边栏、地址栏）。
    private func openInPreviewer(_ entry: ISHDirEntry) {
        WindowManager.shared.open(.previewer, contextPath: fullPath(for: entry))
    }

    private func deleteEntry(_ entry: ISHDirEntry) {
        let full = fullPath(for: entry)
        Task {
            let cmd = entry.isDirectory ? "rm -rf \"\(full)\"" : "rm \"\(full)\""
            _ = try? await bridge.execute(cmd)
            await load()
        }
    }

    // MARK: - Path helpers

    /// 规范化路径：去掉末尾多余 /、保证以 / 开头、折叠冗余分隔符。
    /// 若传入的路径不存在，listDir 会失败并在 UI 显示空内容（按需求）。
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = "/" }
        if !s.hasPrefix("/") { s = "/" + s }
        // 折叠多个连续斜杠
        while s.contains("//") {
            s = s.replacingOccurrences(of: "//", with: "/")
        }
        // 去掉末尾斜杠（除了根目录）
        if s.count > 1 && s.hasSuffix("/") {
            s = String(s.dropLast())
        }
        return s
    }
}

#Preview {
    FilesView()
        .preferredColorScheme(.dark)
}
