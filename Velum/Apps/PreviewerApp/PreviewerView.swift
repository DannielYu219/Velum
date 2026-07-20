//
//  PreviewerView.swift
//  Velum
//
//  Universal previewer App — renders PDF / images / video / audio / Markdown /
//  HTML / Office documents from a fakefs path or a remote URL.
//
//  Layout:
//    ┌── custom title bar (44pt) — Trinity + address field + load + sidebar toggle ──┐
//    ├── sidebar (embedded Files directory index) ──┬── preview renderer ────────────┤
//    └──────────────────────────────────────────────────────────────────────────────┘
//
//  The title bar follows the custom-title-bar drag protocol (onDragChanged /
//  onDrag, coordinateSpace: .global, dragOrigin set once).
//

import SwiftUI

struct PreviewerView: View {
    let onClose: () -> Void
    let onMinimize: () -> Void
    let onZoom: () -> Void
    let onFocus: () -> Void
    let onDrag: (CGPoint) -> Void
    let onDragChanged: (CGPoint) -> Void
    let isMaximized: Bool
    let position: CGPoint
    /// 初始 fakefs 路径；非空时会在首次出现时自动加载该文件。
    let initialPath: String?

    @StateObject private var vm = PreviewerViewModel()

    init(
        onClose: @escaping () -> Void = {},
        onMinimize: @escaping () -> Void = {},
        onZoom: @escaping () -> Void = {},
        onFocus: @escaping () -> Void = {},
        onDrag: @escaping (CGPoint) -> Void = { _ in },
        onDragChanged: @escaping (CGPoint) -> Void = { _ in },
        isMaximized: Bool = false,
        position: CGPoint = .zero,
        initialPath: String? = nil
    ) {
        self.onClose = onClose
        self.onMinimize = onMinimize
        self.onZoom = onZoom
        self.onFocus = onFocus
        self.onDrag = onDrag
        self.onDragChanged = onDragChanged
        self.isMaximized = isMaximized
        self.position = position
        self.initialPath = initialPath
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部工具栏：地址栏 + 加载/侧栏切换 — 不负责拖拽（由 DesktopWindow 标题栏统一处理）
            toolbar
            Divider().background(Color.white.opacity(0.1))
            contentArea
        }
        .background(Color.clear)
        .task {
            // 侧栏数据懒加载
            if vm.sidebarEntries.isEmpty { await vm.loadSidebar() }
        }
        .task(id: initialPath) {
            // 首次出现 / contextPath 变化时自动加载该文件
            guard let p = initialPath, !p.isEmpty else { return }
            if vm.addressText != p {
                await vm.loadFromPath(p)
            }
        }
    }

    // MARK: - Toolbar (no drag — DesktopWindow provides draggable title bar)

    @ViewBuilder
    private var toolbar: some View {
        GeometryReader { geo in
            let addrWidth = min(geo.size.width * 0.5, 420)
            HStack(spacing: 10) {
                ChromeToolButton(systemName: "sidebar.left", isActive: vm.showSidebar) {
                    withAnimation(WindowMotion.micro) { vm.showSidebar.toggle() }
                }

                Spacer(minLength: 8)

                ChromeAddressField(
                    placeholder: "输入路径或网址",
                    text: $vm.addressText,
                    leadingIcon: addressIcon,
                    leadingIconColor: addressIconColor,
                    onSubmit: { Task { await vm.loadPreview() } }
                )
                .frame(width: addrWidth)

                Spacer(minLength: 8)

                ChromeToolButton(systemName: "arrow.forward.circle.fill") {
                    Task { await vm.loadPreview() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(height: 36)
    }

    private var addressIcon: String {
        let a = vm.addressText.lowercased()
        if a.hasPrefix("https://") { return "lock.fill" }
        if a.hasPrefix("http://") { return "lock.open.fill" }
        if a.hasPrefix("/") { return "folder.fill" }
        return "magnifyingglass"
    }

    private var addressIconColor: Color {
        let a = vm.addressText.lowercased()
        if a.hasPrefix("https://") { return .green }
        if a.hasPrefix("http://") { return .orange }
        return .secondary
    }

    // MARK: - Content area (sidebar + renderer)

    @ViewBuilder
    private var contentArea: some View {
        HStack(spacing: 0) {
            if vm.showSidebar {
                sidebar
                    .frame(width: 260)
                    .background(Color.black.opacity(0.15))
                Divider().background(Color.white.opacity(0.1))
            }
            PreviewRendererView(state: vm.previewState)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.05))
        }
    }

    // MARK: - Sidebar (embedded Files directory index)

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            // Path breadcrumb
            HStack(spacing: 8) {
                Button { vm.navigateUp() } label: {
                    Image(systemName: "chevron.up")
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .disabled(vm.sidebarPath == "/")
                .opacity(vm.sidebarPath == "/" ? 0.3 : 1.0)

                ScrollView(.horizontal, showsIndicators: false) {
                    Text(vm.sidebarPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button { Task { await vm.loadSidebar() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider().background(Color.white.opacity(0.1))

            sidebarList
        }
    }

    @ViewBuilder
    private var sidebarList: some View {
        if vm.isLoadingSidebar {
            ProgressView("加载…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = vm.sidebarError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("重试") { Task { await vm.loadSidebar() } }
                    .buttonStyle(.bordered)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.sortedSidebarEntries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("空目录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(vm.sortedSidebarEntries) { entry in
                    sidebarRow(entry)
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Color.white.opacity(0.08))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
    }

    @ViewBuilder
    private func sidebarRow(_ entry: ISHDirEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDirectory ? "folder.fill" : fileIcon(for: entry.name))
                .imageScale(.small)
                .foregroundStyle(entry.isDirectory ? Color.accentColor : fileColor(for: entry.name))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.callout)
                    .lineLimit(1)
                if entry.isRegularFile {
                    Text(entry.formattedSize)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if entry.isDirectory {
                vm.navigateInto(entry.name)
            } else {
                Task { await vm.selectFile(entry) }
            }
        }
        // 支持拖拽到桌面：以 fakefs 完整路径作为 NSItemProvider
        .onDrag {
            let full = vm.sidebarPath == "/" ? "/\(entry.name)" : "\(vm.sidebarPath)/\(entry.name)"
            return NSItemProvider(object: full as NSString)
        }
        .contextMenu {
            if entry.isRegularFile {
                Button {
                    let full = vm.sidebarPath == "/" ? "/\(entry.name)" : "\(vm.sidebarPath)/\(entry.name)"
                    WindowManager.shared.open(.viewer, contextPath: full)
                } label: {
                    Label("在查看窗口中打开", systemImage: "doc.text.fill")
                }
            }
            Button {
                let full = vm.sidebarPath == "/" ? "/\(entry.name)" : "\(vm.sidebarPath)/\(entry.name)"
                UIPasteboard.general.string = full
            } label: {
                Label("复制路径", systemImage: "doc.on.doc")
            }
        }
    }

    private func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch PreviewerViewModel.typeFor(ext: ext) {
        case .pdf:       return "doc.richtext.fill"
        case .html:      return "globe"
        case .markdown:  return "doc.text.fill"
        case .image:     return "photo.fill"
        case .video:     return "film.fill"
        case .audio:     return "music.note"
        case .office:    return "doc.fill"
        case .text:      return "doc.plain.fill"
        }
    }

    private func fileColor(for name: String) -> Color {
        let ext = (name as NSString).pathExtension.lowercased()
        switch PreviewerViewModel.typeFor(ext: ext) {
        case .pdf:       return .red
        case .html:      return .blue
        case .markdown:  return .purple
        case .image:     return .teal
        case .video:     return .pink
        case .audio:     return .orange
        case .office:    return .indigo
        case .text:      return .secondary
        }
    }
}

// MARK: - Trinity button (shared shape with other custom-title-bar apps)
// 已移除 — DesktopWindow 统一提供 Trinity 标题栏

#Preview {
    PreviewerView(onClose: {}, onMinimize: {}, onZoom: {}, onFocus: {})
        .preferredColorScheme(.dark)
}
