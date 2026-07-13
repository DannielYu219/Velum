//
//  ContentView.swift
//  Velum
//
//  Phase 2: Full desktop shell — TopBar + Launcher + Windows + Dock.
//  Phase 3: Multi-window — stackable, draggable, resizable, maximizable.
//
//  ZStack layers:
//    1. background wallpaper
//    2. top bar (hidden when frontmost maximized)
//    3. window layer (ForEach — all non-minimized windows, z-ordered)
//    4. launcher overlay
//    5. dock (hidden when frontmost maximized)
//
//  Keyboard shortcuts routed through VelumControl (Phase 1.3).
//

import SwiftUI

struct ContentView: View {
    @ObservedObject private var kernel = Kernel.shared
    @ObservedObject private var control = VelumControl.shared
    @ObservedObject private var wm = WindowManager.shared
    @ObservedObject private var wp = WallpaperManager.shared
    @StateObject private var firstBoot = FirstBootSetup()

    var body: some View {
        ZStack {
            // Layer 1: desktop background
            backgroundLayer

            // Layer 2: top bar — slides up when frontmost window is maximized
            if !wm.hasMaximizedFrontmost {
                VStack {
                    TopBar()
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer()
                }
            }

            // Layer 3: open windows (stackable, z-ordered by array order)
            windowLayer

            // Layer 4: launcher overlay — tap outside to dismiss
            if wm.showLauncher {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if wm.showLauncher {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                wm.showLauncher = false
                            }
                        }
                    }
                LauncherView()
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            // Layer 5: dock — slides down when frontmost window is maximized
            if !wm.hasMaximizedFrontmost {
                VStack {
                    Spacer()
                    Dock()
                }
                .ignoresSafeArea(edges: .bottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Layer 6: first-boot setup overlay
            if firstBoot.isNeeded || firstBoot.phase.isBusy {
                FirstBootOverlay(setup: firstBoot)
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .ignoresSafeArea()
        .background(Color(.systemBackground))
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        .onAppear { kernel.startObserving() }
        .onDisappear { kernel.stopObserving() }
        .task {
            // 启动 MCP Server（JSON-RPC over TCP, localhost:8765）
            try? await MCPServer.shared.start()

            // 当内核就绪后自动执行首次启动配置
            while kernel.state != .ready {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if case .failed = kernel.state { break }
            }
            if kernel.state == .ready {
                await firstBoot.runIfNeeded()
            }
        }
        .background {
            shortcutLayer
        }
    }

    // MARK: - Layers

    @ViewBuilder
    private var backgroundLayer: some View {
        if let image = wp.customImage {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .ignoresSafeArea()
        } else {
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.10, blue: 0.16),
                    Color(red: 0.14, green: 0.18, blue: 0.28)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var windowLayer: some View {
        ForEach(wm.windows) { win in
            DesktopWindow(
                window: win,
                onClose: { wm.close(win.id) },
                onMinimize: { wm.toggleMinimize(win.id) },
                onZoom: { wm.toggleMaximize(win.id) },
                onFocus: { wm.focus(win.id) },
                onDrag: { wm.updatePosition(win.id, position: $0) },
                onResize: { wm.updateSize(win.id, size: $0) }
            )
            .id(win.id)
            .transition(
                // 打开：从底部（Dock 位置）缩放放大 + 淡入；关闭：缩小 + 淡出
                .asymmetric(
                    insertion: .scale(scale: 0.3, anchor: .bottom)
                        .combined(with: .opacity)
                        .combined(with: .offset(y: 200)),
                    removal: .scale(scale: 0.3, anchor: .bottom)
                        .combined(with: .opacity)
                )
            )
        }
    }

    @ViewBuilder
    private var shortcutLayer: some View {
        VStack {
            ForEach(1...7, id: \.self) { n in
                Button("") { control.perform(.switchTTY(n)) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                    .hidden()
            }
            Button("") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    wm.showLauncher.toggle()
                }
            }
            .keyboardShortcut("l", modifiers: .command)
            .hidden()
            Button("") { control.perform(.showTerminalSettings) }
                .keyboardShortcut(",", modifiers: .command)
                .hidden()
            Button("") { control.perform(.clearCurrentScreen) }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
            Button("") { control.perform(.showTaskSwitcher) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .hidden()
            Button("") { control.perform(.increaseFont) }
                .keyboardShortcut("=", modifiers: .command).hidden()
            Button("") { control.perform(.decreaseFont) }
                .keyboardShortcut("-", modifiers: .command).hidden()
            Button("") { control.perform(.resetFont) }
                .keyboardShortcut("0", modifiers: .command).hidden()
            Button("") { control.perform(.toggleAppearance) }
                .keyboardShortcut("a", modifiers: [.command, .shift]).hidden()
            Button("") {
                if let id = wm.frontmostID { wm.close(id) }
            }
            .keyboardShortcut("w", modifiers: .command).hidden()
            Button("") {
                if let id = wm.frontmostID { wm.toggleMinimize(id) }
            }
            .keyboardShortcut("m", modifiers: .command).hidden()
        }
    }
}

// MARK: - Desktop Window
//
// Window container: glass background + rounded clip + title bar (Trinity) + content.
// Draggable by the title bar, resizable via bottom-right handle, maximizable.
//

private struct DesktopWindow: View {
    let window: AppWindow
    let onClose: () -> Void
    let onMinimize: () -> Void
    let onZoom: () -> Void
    let onFocus: () -> Void
    let onDrag: (CGPoint) -> Void
    let onResize: (CGSize) -> Void

    // Local state — authoritative during drag/resize. Synced from model via onChange.
    @State private var localPosition: CGPoint
    @State private var localSize: CGSize
    @State private var dragOrigin: CGPoint?
    @State private var isDragging: Bool = false

    init(
        window: AppWindow,
        onClose: @escaping () -> Void,
        onMinimize: @escaping () -> Void,
        onZoom: @escaping () -> Void,
        onFocus: @escaping () -> Void,
        onDrag: @escaping (CGPoint) -> Void,
        onResize: @escaping (CGSize) -> Void
    ) {
        self.window = window
        self.onClose = onClose
        self.onMinimize = onMinimize
        self.onZoom = onZoom
        self.onFocus = onFocus
        self.onDrag = onDrag
        self.onResize = onResize
        _localPosition = State(initialValue: window.position)
        _localSize = State(initialValue: window.size)
    }

    /// 计算对应 Dock 图标在屏幕上的中心位置（最小化动画目标点）。
    private func dockIconCenter(_ screenSize: CGSize) -> CGPoint {
        guard let appIndex = VelumApp.allCases.firstIndex(of: window.app) else {
            return CGPoint(x: screenSize.width / 2, y: screenSize.height - 50)
        }
        let iconCount = VelumApp.allCases.count
        let iconSlot: CGFloat = 76          // 每个图标槽位宽度（68 图标 + 4×2 padding）
        let dockPadding: CGFloat = 8        // Dock capsule 外层 padding
        let dockTotalWidth = CGFloat(iconCount) * iconSlot + dockPadding * 2
        let dockStart = (screenSize.width - dockTotalWidth) / 2
        let x = dockStart + dockPadding + iconSlot / 2 + CGFloat(appIndex) * iconSlot
        let y = screenSize.height - 50      // Dock 图标大致中心 y
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        GeometryReader { geo in
            let isMax = window.isMaximized
            let isMin = window.isMinimized
            let winSize = isMax ? geo.size : localSize
            let normalCenter = isMax
                ? CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                : CGPoint(
                    x: localPosition.x + localSize.width / 2,
                    y: localPosition.y + localSize.height / 2
                )
            // 最小化时飞向 Dock 图标位置
            let winCenter = isMin ? dockIconCenter(geo.size) : normalCenter

            VStack(spacing: 0) {
                // Title bar — hidden for browser (browser has its own integrated bar)
                if window.app != .browser {
                    HStack(spacing: 0) {
                        Trinity(
                            onClose: onClose,
                            onMinimize: onMinimize,
                            onZoom: onZoom
                        )
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onFocus() }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if !window.isMaximized {
                                    if dragOrigin == nil {
                                        dragOrigin = localPosition
                                        isDragging = true
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
                                isDragging = false
                            }
                    )
                }

                // Content area
                AppHostView(
                    app: window.app,
                    contextPath: window.contextPath,
                    onClose: onClose,
                    onMinimize: onMinimize,
                    onZoom: onZoom,
                    onFocus: onFocus,
                    onDrag: onDrag,
                    isMaximized: window.isMaximized,
                    position: localPosition
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: winSize.width, height: winSize.height)
            .background(
                GlassSurface(.regular, in: RoundedRectangle(cornerRadius: isMax ? 0 : 24, style: .continuous))
            )
            .clipShape(RoundedRectangle(cornerRadius: isMax ? 0 : 24, style: .continuous))
            .ignoresSafeArea(edges: isMax ? .all : [])
            .overlay(alignment: .bottomTrailing) {
                if !isMax && !isMin {
                    ResizeHandle(
                        currentSize: localSize,
                        onResize: { newSize in localSize = newSize },
                        onEnd: { finalSize in onResize(finalSize) }
                    )
                }
            }
            // 最小化动画：缩放到 dock 图标大小 + 透明
            .scaleEffect(isMin ? 0.05 : 1, anchor: .center)
            .opacity(isMin ? 0 : 1)
            .position(winCenter)
            .allowsHitTesting(!isMin)
            .onChange(of: window.position) { newPos in
                // Sync from model when not actively dragging (external changes only).
                if !isDragging { localPosition = newPos }
            }
            .onChange(of: window.size) { newSize in
                if !isDragging { localSize = newSize }
            }
        }
    }
}

// MARK: - Resize Handle (bottom-right corner)

private struct ResizeHandle: View {
    let currentSize: CGSize
    let onResize: (CGSize) -> Void
    let onEnd: (CGSize) -> Void
    @State private var resizeOrigin: CGSize?

    private let minSize = CGSize(width: 400, height: 300)

    var body: some View {
        Path { path in
            let s: CGFloat = 12
            path.move(to: CGPoint(x: s, y: 4))
            path.addLine(to: CGPoint(x: 4, y: s))
            path.move(to: CGPoint(x: s, y: 8))
            path.addLine(to: CGPoint(x: 8, y: s))
        }
        .stroke(Color.white.opacity(0.3), lineWidth: 1.5)
        .frame(width: 16, height: 16)
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if resizeOrigin == nil {
                        resizeOrigin = currentSize
                    }
                    let newWidth = max(minSize.width, resizeOrigin!.width + value.translation.width)
                    let newHeight = max(minSize.height, resizeOrigin!.height + value.translation.height)
                    onResize(CGSize(width: newWidth, height: newHeight))
                }
                .onEnded { _ in
                    onEnd(currentSize)
                    resizeOrigin = nil
                }
        )
    }
}

// MARK: - Trinity (macOS close/min/zoom) — 新版独立圆形按钮

private struct Trinity: View {
    let onClose: () -> Void
    let onMinimize: () -> Void
    let onZoom: () -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                TrinityButton(tint: .red, symbol: "xmark", action: onClose)
                    .padding(.trailing, 4)
                TrinityButton(tint: .yellow, symbol: "minus", action: onMinimize)
                    .padding(.horizontal, 4)
                TrinityButton(tint: .green, symbol: "square", action: onZoom)
                    .padding(.leading, 4)
            }
        }
        .clipped()
        .padding(8)
    }
}

private struct TrinityButton: View {
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

// MARK: - First Boot Overlay

private struct FirstBootOverlay: View {
    @ObservedObject var setup: FirstBootSetup

    var body: some View {
        ZStack {
            // 半透明遮罩
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            // 中央卡片
            VStack(spacing: 24) {
                // 图标
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 80, height: 80)
                    Image(systemName: iconForPhase)
                        .font(.system(size: 36))
                        .foregroundStyle(.tint)
                }

                // 标题
                Text("正在配置 Velum 环境")
                    .font(.title2.bold())

                // 状态
                HStack(spacing: 8) {
                    if setup.phase.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(setup.phase.label)
                        .foregroundStyle(.secondary)
                }

                // 进度条
                progressBars

                // 日志（可滚动）
                if !setup.logLines.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(setup.logLines.indices, id: \.self) { i in
                                Text(setup.logLines[i])
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                    .padding(8)
                    .background(Color.black.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // 失败时显示重试按钮
                if case .failed = setup.phase {
                    Button("重试") {
                        Task { await setup.runIfNeeded() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(32)
            .frame(maxWidth: 380)
            .background {
                GlassSurface(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private var iconForPhase: String {
        switch setup.phase {
        case .pending: return "clock"
        case .switchingMirror: return "network"
        case .updatingRepos: return "arrow.triangle.2.circlepath"
        case .installingPackages: return "shippingbox"
        case .configuringEnv: return "wrench.and.screwdriver"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var progressBars: some View {
        let steps: [(FirstBootSetup.Phase, String)] = [
            (.switchingMirror, "切换国内镜像源"),
            (.updatingRepos, "更新软件源"),
            (.installingPackages, "安装预装包"),
            (.configuringEnv, "配置环境"),
        ]
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(steps.indices, id: \.self) { i in
                let (stepPhase, label) = steps[i]
                let status = stepStatus(stepPhase, index: i)
                HStack(spacing: 8) {
                    Image(systemName: status.icon)
                        .foregroundStyle(status.color)
                        .frame(width: 16)
                    Text(label)
                        .font(.callout)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func stepStatus(_ stepPhase: FirstBootSetup.Phase, index: Int) -> (icon: String, color: Color) {
        let allPhases: [FirstBootSetup.Phase] = [.switchingMirror, .updatingRepos, .installingPackages, .configuringEnv]
        let currentIndex = allPhases.firstIndex { $0 == setup.phase } ?? -1

        if case .completed = setup.phase {
            return ("checkmark.circle.fill", .green)
        }
        if case .failed = setup.phase {
            return index <= currentIndex ? ("exclamationmark.circle.fill", .orange) : ("circle", .secondary)
        }

        if index < currentIndex {
            return ("checkmark.circle.fill", .green)
        } else if index == currentIndex {
            return ("circle.dotted", .accentColor)
        } else {
            return ("circle", .secondary)
        }
    }
}

// MARK: - Obj-C Bridge

@objc(VLMDesktopFactory)
public class DesktopFactory: NSObject {
    @objc public static func makeRootViewController() -> UIViewController {
        return UIHostingController(rootView: ContentView())
    }
}
