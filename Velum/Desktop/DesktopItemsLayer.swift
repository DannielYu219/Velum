//
//  DesktopItemsLayer.swift
//  Velum
//
//  桌面图标层 — 在壁纸之上、窗口之下渲染桌面文件图标。
//
//  功能：
//  - 渲染所有 DesktopItemsManager 中的桌面引用（图标 + 文件名）
//  - 支持从 FilesView / PreviewerView 侧栏拖拽文件到桌面（.onDrop 接收 fakefs 路径字符串）
//  - 桌面图标可拖动重定位（DragGesture）
//  - 长按或右键图标显示菜单（打开 / 复制路径 / 从桌面移除 / 从磁盘删除）
//  - 空白桌面右键菜单：新建文件 / 新建文件夹 / 整理图标
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - 桌面图标层

struct DesktopItemsLayer: View {
    let canvas: CGSize
    @ObservedObject private var manager = DesktopItemsManager.shared
    @ObservedObject private var wm = WindowManager.shared

    var body: some View {
        // 画布尺寸未就绪时不渲染（避免误置）
        if canvas.width <= 1 || canvas.height <= 1 {
            EmptyView()
        } else {
            ZStack(alignment: .topLeading) {
                // 透明背景 — 仅用于接收 drop 与 contextMenu
                Color.clear
                    .contentShape(Rectangle())
                    .onDrop(of: [.text], delegate: DesktopDropDelegate(canvas: canvas, manager: manager))
                    .contextMenu {
                        DesktopContextMenu(manager: manager, canvas: canvas)
                    }
                    .onTapGesture {
                        // 点击空白处取消选中
                        manager.selection = nil
                    }

                // 渲染图标
                ForEach(manager.items) { item in
                    DesktopItemView(item: item, canvas: canvas)
                        .offset(x: item.position.x, y: item.position.y)
                }
            }
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            .clipped()
            .onChange(of: canvas) { newSize in
                manager.reclamp(in: newSize)
            }
        }
    }
}

// MARK: - 桌面单个图标

private struct DesktopItemView: View {
    let item: DesktopItem
    let canvas: CGSize
    @ObservedObject private var manager = DesktopItemsManager.shared
    @ObservedObject private var wm = WindowManager.shared

    @State private var dragOrigin: CGPoint?
    @State private var isDragging: Bool = false
    @State private var localPosition: CGPoint
    /// 异步从 fakefs stat 拿到的是否目录；用于显示文件夹图标。
    @State private var isDirectory: Bool = false
    /// 路径在 fakefs 中是否还存在；不存在时降低不透明度并提示。
    @State private var missingOnDisk: Bool = false

    init(item: DesktopItem, canvas: CGSize) {
        self.item = item
        self.canvas = canvas
        _localPosition = State(initialValue: item.position)
    }

    private var isSelected: Bool {
        manager.selection == item.id
    }

    var body: some View {
        VStack(spacing: 6) {
            iconImage
            Text(item.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 108)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(0.45))
                )
        }
        .frame(width: DesktopItemsManager.iconSize.width, height: DesktopItemsManager.iconSize.height)
        .background(
            // 选中高亮
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(isSelected ? 0.22 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            open()
        }
        .onTapGesture(count: 1) {
            manager.selection = item.id
        }
        .contextMenu {
            Button {
                open()
            } label: {
                Label("打开", systemImage: "arrow.up.forward.square")
            }
            if !isDirectory {
                Button {
                    openInViewer()
                } label: {
                    Label("在查看窗口中打开", systemImage: "doc.text.fill")
                }
                Button {
                    openInPreviewer()
                } label: {
                    Label("在预览 App 中打开", systemImage: "eye.fill")
                }
            }
            Button {
                UIPasteboard.general.string = item.path
            } label: {
                Label("复制路径", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                manager.remove(id: item.id)
            } label: {
                Label("从桌面移除", systemImage: "minus.circle")
            }
            Button(role: .destructive) {
                Task { await deleteFromDisk() }
            } label: {
                Label("从磁盘删除", systemImage: "trash")
            }
        }
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .local)
                .onChanged { value in
                    if dragOrigin == nil {
                        dragOrigin = localPosition
                        isDragging = true
                    }
                    let raw = CGPoint(
                        x: dragOrigin!.x + value.translation.width,
                        y: dragOrigin!.y + value.translation.height
                    )
                    let clamped = DesktopItemsManager.clampPosition(raw, in: canvas)
                    localPosition = clamped
                }
                .onEnded { _ in
                    manager.updatePosition(id: item.id, position: localPosition)
                    dragOrigin = nil
                    isDragging = false
                }
        )
        .scaleEffect(isDragging ? 1.08 : 1.0)
        .opacity(isDragging ? 0.85 : (missingOnDisk ? 0.4 : 1.0))
        .animation(.easeOut(duration: 0.15), value: isDragging)
        .onChange(of: item.position) { newP in
            // 外部更新（画布变化、夹取等）同步本地
            if !isDragging { localPosition = newP }
        }
        .task(id: item.path) {
            await refreshStat()
        }
    }

    /// 异步从 fakefs 拉一次 stat，更新 isDirectory / missingOnDisk。
    private func refreshStat() async {
        let bridge = ISHBridge.shared
        if await bridge.exists(item.path) == false {
            missingOnDisk = true
            isDirectory = false
            return
        }
        missingOnDisk = false
        if let stat = try? await bridge.stat(item.path) {
            isDirectory = stat.mode & 0o170000 == 0o040000
        } else {
            isDirectory = false
        }
    }

    // MARK: - 子视图

    @ViewBuilder
    private var iconImage: some View {
        ZStack {
            // 半透明圆角玻璃背景（图标框 84×84）
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.10))
                .frame(width: 84, height: 84)
            Image(systemName: iconName)
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(iconColor)
                .imageScale(.large)
        }
    }

    private var iconName: String {
        if isDirectory { return "folder.fill" }
        // 通过扩展名推断文件图标
        let ext = item.ext
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

    private var iconColor: Color {
        if isDirectory { return .accentColor }
        let ext = item.ext
        switch PreviewerViewModel.typeFor(ext: ext) {
        case .pdf:       return .red
        case .html:      return .blue
        case .markdown:  return .purple
        case .image:     return .teal
        case .video:     return .pink
        case .audio:     return .orange
        case .office:    return .indigo
        case .text:      return .white
        }
    }

    // MARK: - Actions

    /// 默认打开：目录 → Files App；文件 → 查看窗口（专用文件查看器）
    private func open() {
        if isDirectory {
            wm.open(.files, contextPath: item.path)
        } else {
            openInViewer()
        }
    }

    /// 在专用文件查看窗口中打开（无侧边栏，仅显示文件内容）。
    private func openInViewer() {
        wm.open(.viewer, contextPath: item.path)
    }

    /// 在预览 App 中打开（带侧边栏、地址栏）。
    private func openInPreviewer() {
        wm.open(.previewer, contextPath: item.path)
    }

    private func deleteFromDisk() async {
        let path = item.path
        // 先从桌面移除引用，避免悬空
        manager.remove(id: item.id)
        _ = try? await ISHBridge.shared.execute("rm -rf \"\(path)\"")
    }
}

// MARK: - 空白桌面右键菜单

private struct DesktopContextMenu: View {
    @ObservedObject var manager: DesktopItemsManager
    let canvas: CGSize

    var body: some View {
        Button {
            Task {
                _ = await manager.createNewTextFile(at: defaultPosition())
            }
        } label: {
            Label("新建文件", systemImage: "doc.badge.plus")
        }
        Button {
            Task {
                _ = await manager.createNewFolder(at: defaultPosition())
            }
        } label: {
            Label("新建文件夹", systemImage: "folder.badge.plus")
        }
        Divider()
        Button {
            manager.rearrange(in: canvas)
        } label: {
            Label("整理图标", systemImage: "rectangle.grid.3x2")
        }
        Button(role: .destructive) {
            manager.removeAll()
        } label: {
            Label("清空桌面", systemImage: "trash.slash")
        }
    }

    /// 新建文件的默认位置 — 在画布左上角附近，依次错开。
    /// 步长按当前图标尺寸自适应。
    private func defaultPosition() -> CGPoint {
        let count = manager.items.count
        let cols = 6
        let col = count % cols
        let row = count / cols
        let stepX = DesktopItemsManager.iconSize.width + 8
        let stepY = DesktopItemsManager.iconSize.height + 8
        return CGPoint(x: 24 + CGFloat(col) * stepX, y: 36 + CGFloat(row) * stepY)
    }
}

// MARK: - Drop Delegate

struct DesktopDropDelegate: DropDelegate {
    let canvas: CGSize
    let manager: DesktopItemsManager

    func performDrop(info: DropInfo) -> Bool {
        let location = info.location  // 在所附视图的本地坐标系（即画布坐标系）

        var accepted = false
        let providers = info.itemProviders(for: [.text, .utf8PlainText])
        for provider in providers {
            // 优先尝试 NSString（含路径）
            if provider.canLoadObject(ofClass: NSString.self) {
                _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                    guard let str = value as? String else { return }
                    let path = str.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !path.isEmpty else { return }
                    DispatchQueue.main.async {
                        manager.add(path: path, position: location)
                    }
                }
                accepted = true
            }
        }
        return accepted
    }
}
