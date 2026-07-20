//
//  ContentView.swift
//  Velum
//
//  Phase 2/3: SwiftUI desktop shell.
//
//  Layout contract (pure SwiftUI):
//  1. Root GeometryReader is the ONLY canvas size source — exactly the size proposed by parent.
//  2. Desktop is frame(width:height: geo.size) + clipped. No ignoresSafeArea expansion.
//  3. App windows are painted inside a fixed canvas via overlay(alignment:.topLeading) + offset.
//     Using .offset alone as a sibling layout child is avoided — it still participates in
//     parent size negotiation and can make the desktop larger than the screen (L/R-symmetric).
//  4. Keyboard isolation is .ignoresSafeArea(.keyboard) only on the desktop root.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject private var kernel = Kernel.shared
    @ObservedObject private var control = VelumControl.shared
    @ObservedObject private var wm = WindowManager.shared
    @ObservedObject private var wp = WallpaperManager.shared
    @StateObject private var firstBoot = FirstBootSetup()

    var body: some View {
        // GeometryReader fills whatever the hosting controller proposes — and NOTHING more.
        GeometryReader { geo in
            let canvas = geo.size

            desktop(canvas: canvas)
                .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
                .clipped()
                .contentShape(Rectangle())
                .environment(\.desktopCanvasSize, canvas)
                .onAppear { wm.updateCanvasSize(canvas) }
                .onChange(of: canvas) { wm.updateCanvasSize($0) }
        }
        // Take exactly parent proposal; do not invent a preferred larger sizeres.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .ignoresSafeArea(.keyboard)
        .background(Color.black)
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        .onAppear { kernel.startObserving() }
        .onDisappear { kernel.stopObserving() }
        .task {
            LocalModelCleanup.cleanUp()
            try? await MCPServer.shared.start()
            while kernel.state != .ready {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if case .failed = kernel.state { break }
            }
            if kernel.state == .ready {
                await firstBoot.runIfNeeded()
                // 注入三种形态的演示第三方 App（幂等；首次会把 H5 演示包写进 fakefs）。
                await AppRegistry.shared.seedDemosIfNeeded()
            }
        }
        // Shortcuts must not contribute size. Zero-frame overlay.
        .overlay(alignment: .topLeading) {
            shortcutLayer
                .frame(width: 0, height: 0)
                .opacity(0)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Desktop canvas (all chrome constrained to `canvas`)

    @ViewBuilder
    private func desktop(canvas: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            // Layer 1: wallpaper — exact pixel size
            background(canvas: canvas)

            // Layer 1.5: desktop items (file icons placed on desktop)
            DesktopItemsLayer(canvas: canvas)

            // Layer 2: windows — fixed canvas with internal absolute placement
            windowCanvas(canvas: canvas)

            // Layer 3: launcher
            if wm.showLauncher {
                Color.black.opacity(0.001)
                    .frame(width: canvas.width, height: canvas.height)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            wm.showLauncher = false
                        }
                    }
                LauncherView()
                    .frame(width: canvas.width, height: canvas.height)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            // Layer 4: dock (slide out when maximized — clipped by canvas)
            if !wm.hasMaximizedFrontmost {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Dock()
                }
                .frame(width: canvas.width, height: canvas.height)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Layer 5: first-boot
            if firstBoot.isNeeded || firstBoot.phase.isBusy {
                FirstBootOverlay(setup: firstBoot)
                    .frame(width: canvas.width, height: canvas.height)
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .clipped()
    }

    @ViewBuilder
    private func background(canvas: CGSize) -> some View {
        Group {
            if let image = wp.customImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.08, green: 0.10, blue: 0.16),
                        Color(red: 0.14, green: 0.18, blue: 0.28)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
    }

    /// Fixed-size canvas. Windows are overlays so they never change this frame.
    @ViewBuilder
    private func windowCanvas(canvas: CGSize) -> some View {
        // Clear base establishes exact layout size of the window layer.
        Color.clear
            .frame(width: canvas.width, height: canvas.height)
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
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
                .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            }
            .clipped()
    }

    @ViewBuilder
    private var shortcutLayer: some View {
        VStack {
            ForEach(1...7, id: \.self) { n in
                Button("") { control.perform(.switchTTY(n)) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
            Button("") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    wm.showLauncher.toggle()
                }
            }
            .keyboardShortcut("l", modifiers: .command)
            Button("") { control.perform(.showTerminalSettings) }
                .keyboardShortcut(",", modifiers: .command)
            Button("") { control.perform(.clearCurrentScreen) }
                .keyboardShortcut("k", modifiers: .command)
            Button("") { control.perform(.showTaskSwitcher) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("") { control.perform(.increaseFont) }
                .keyboardShortcut("=", modifiers: .command)
            Button("") { control.perform(.decreaseFont) }
                .keyboardShortcut("-", modifiers: .command)
            Button("") { control.perform(.resetFont) }
                .keyboardShortcut("0", modifiers: .command)
            Button("") { control.perform(.toggleAppearance) }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("") {
                if let id = wm.frontmostID { wm.close(id) }
            }
            .keyboardShortcut("w", modifiers: .command)
            Button("") {
                if let id = wm.frontmostID { wm.toggleMinimize(id) }
            }
            .keyboardShortcut("m", modifiers: .command)
        }
    }
}

// MARK: - Desktop canvas environment

private struct DesktopCanvasSizeKey: EnvironmentKey {
    static let defaultValue: CGSize = .zero
}

private extension EnvironmentValues {
    var desktopCanvasSize: CGSize {
        get { self[DesktopCanvasSizeKey.self] }
        set { self[DesktopCanvasSizeKey.self] = newValue }
    }
}

// MARK: - Desktop Window
//
// Pure SwiftUI absolute placement inside a FIXED parent canvas:
//   Chromium body.frame(w,h)
//   → wrapped in Color.clear.frame(canvas).overlay(alignment:.topLeading) { body.offset }
// so the window never alters the parent ZStack's layout size.

private struct DesktopWindow: View {
    let window: AppWindow
    let onClose: () -> Void
    let onMinimize: () -> Void
    let onZoom: () -> Void
    let onFocus: () -> Void
    let onDrag: (CGPoint) -> Void
    let onResize: (CGSize) -> Void

    @State private var localPosition: CGPoint
    @State private var localSize: CGSize
    @State private var dragOrigin: CGPoint?
    @State private var isDragging: Bool = false
    @Environment(\.desktopCanvasSize) private var canvasSize

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

    private var bounds: CGRect {
        CGRect(origin: .zero, size: canvasSize)
    }

    private func dockIconCenter(_ screenSize: CGSize) -> CGPoint {
        guard let appIndex = VelumApp.allCases.firstIndex(of: window.app) else {
            return CGPoint(x: screenSize.width / 2, y: max(0, screenSize.height - 50))
        }
        let iconCount = VelumApp.allCases.count
        let iconSlot: CGFloat = 76
        let dockPadding: CGFloat = 8
        let dockTotalWidth = CGFloat(iconCount) * iconSlot + dockPadding * 2
        let dockStart = (screenSize.width - dockTotalWidth) / 2
        let x = dockStart + dockPadding + iconSlot / 2 + CGFloat(appIndex) * iconSlot
        let y = max(0, screenSize.height - 50)
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        let isMax = window.isMaximized
        let isMin = window.isMinimized
        // Wait until canvas known — report zero preferred size so we don't inflate parent.
        if canvasSize.width <= 1 || canvasSize.height <= 1 {
            Color.clear.frame(width: 0, height: 0)
        } else {
            // 单一视图树：maximize 只改变参数（尺寸/圆角/原点），不改变视图结构。
            // 这样切换最大化/窗口化时，AppHostView 内部的 @State（如 FilesView 的
            // path、entries、滚动位置等）不会被销毁重建。
            let renderSize = isMax ? canvasSize : WindowManager.clamp(size: localSize, in: bounds)
            let cornerRadius: CGFloat = isMax ? 0 : 24
            let showResize = isMax ? false : !isMin

            canvasHost(size: canvasSize, isMin: isMin, contentSize: isMax ? nil : renderSize) {
                windowBody(
                    size: renderSize,
                    maximized: isMax,
                    cornerRadius: cornerRadius,
                    showResize: showResize
                )
                .scaleEffect(isMin ? 0.05 : 1, anchor: .center)
                .opacity(isMin ? 0 : 1)
                .allowsHitTesting(!isMin)
            }
            .onAppear { reclamp() }
            .onChange(of: window.position) { p in
                if !isDragging { localPosition = p }
            }
            .onChange(of: window.size) { s in
                if !isDragging { localSize = s }
            }
            .onChange(of: canvasSize) { _ in reclamp() }
        }
    }

    /// The critical isolation box: layout size is ALWAYS `size` (the canvas).
    /// Content is only visually shifted via offset inside overlay — never changes layout size.
    @ViewBuilder
    private func canvasHost<Content: View>(
        size: CGSize,
        isMin: Bool,
        contentSize: CGSize? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let bodySize = contentSize ?? size
        let origin: CGPoint = {
            if isMin {
                let dock = dockIconCenter(size)
                return CGPoint(
                    x: dock.x - bodySize.width / 2,
                    y: dock.y - bodySize.height / 2
                )
            }
            if let contentSize {
                return WindowManager.clamp(position: localPosition, size: contentSize, in: bounds)
            }
            return .zero
        }()

        Color.clear
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .topLeading) {
                content()
                    .offset(x: origin.x, y: origin.y)
            }
            .clipped()
            // Host itself must not grow: fixed frames only.
            .frame(width: size.width, height: size.height)
    }

    @ViewBuilder
    private func windowBody(
        size: CGSize,
        maximized: Bool,
        cornerRadius: CGFloat,
        showResize: Bool
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        VStack(spacing: 0) {
            if window.app != .browser {
                HStack(spacing: 0) {
                    WindowTrinity(onClose: onClose, onMinimize: onMinimize, onZoom: onZoom)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { onFocus() }
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            guard !maximized else { return }
                            if dragOrigin == nil {
                                dragOrigin = localPosition
                                isDragging = true
                            }
                            let raw = CGPoint(
                                x: dragOrigin!.x + value.translation.width,
                                y: dragOrigin!.y + value.translation.height
                            )
                            localPosition = WindowManager.clamp(position: raw, size: localSize, in: bounds)
                        }
                        .onEnded { _ in
                            guard !maximized else { return }
                            onDrag(localPosition)
                            dragOrigin = nil
                            isDragging = false
                        }
                )
            }

            AppHostView(
                app: window.app,
                contextPath: window.contextPath,
                onClose: onClose, onMinimize: onMinimize, onZoom: onZoom,
                onFocus: onFocus,
                onDrag: { pos in
                    guard !maximized else { return }
                    let clamped = WindowManager.clamp(position: pos, size: localSize, in: bounds)
                    onDrag(clamped)
                    isDragging = false
                },
                onDragChanged: { newPos in
                    guard !maximized else { return }
                    isDragging = true
                    localPosition = WindowManager.clamp(position: newPos, size: localSize, in: bounds)
                },
                isMaximized: maximized,
                position: maximized ? .zero : localPosition,
                thirdPartyId: window.thirdPartyId
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .simultaneousGesture(TapGesture().onEnded { onFocus() })
        }
        .frame(width: size.width, height: size.height)
        .background {
            if cornerRadius > 0 {
                GlassSurface(.regular, in: shape)
            } else {
                GlassSurface(.regular, in: Rectangle())
            }
        }
        .clipShape(cornerRadius > 0 ? AnyShape(shape) : AnyShape(Rectangle()))
        .overlay(alignment: .bottomTrailing) {
            if showResize {
                ResizeHandle(
                    currentSize: localSize,
                    onResize: { newSize in
                        let next = WindowManager.clamp(size: newSize, in: bounds)
                        localSize = next
                        localPosition = WindowManager.clamp(position: localPosition, size: next, in: bounds)
                    },
                    onEnd: { finalSize in
                        let next = WindowManager.clamp(size: finalSize, in: bounds)
                        localSize = next
                        localPosition = WindowManager.clamp(position: localPosition, size: next, in: bounds)
                        onResize(next)
                        onDrag(localPosition)
                    }
                )
            }
        }
    }

    private func reclamp() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let fitted = WindowManager.clamp(size: localSize, in: bounds)
        localSize = fitted
        localPosition = WindowManager.clamp(position: localPosition, size: fitted, in: bounds)
    }
}

// Type-erased shape for conditional clipShape
private struct AnyShape: Shape {
    private let _path: (CGRect) -> Path
    init<S: Shape>(_ shape: S) {
        _path = { shape.path(in: $0) }
    }
    func path(in rect: CGRect) -> Path { _path(rect) }
}

// MARK: - Resize Handle

private struct ResizeHandle: View {
    let currentSize: CGSize
    let onResize: (CGSize) -> Void
    let onEnd: (CGSize) -> Void
    @State private var resizeOrigin: CGSize?

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
                    if resizeOrigin == nil { resizeOrigin = currentSize }
                    let raw = CGSize(
                        width: resizeOrigin!.width + value.translation.width,
                        height: resizeOrigin!.height + value.translation.height
                    )
                    onResize(WindowManager.clamp(size: raw))
                }
                .onEnded { _ in
                    onEnd(WindowManager.clamp(size: currentSize))
                    resizeOrigin = nil
                }
        )
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


// MARK: - SwiftUI host bridge (minimal UIKit — only required to set root VC)

/// Thin UIHostingController. No SafeAreaFree wrappers, no frame fighting.
/// Canvas sizing is owned entirely by SwiftUI GeometryReader above.
private final class DesktopHostingController: UIHostingController<ContentView> {
    override init(rootView: ContentView) {
        super.init(rootView: rootView)
        if #available(iOS 16.4, *) {
            safeAreaRegions = []
        }
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        if #available(iOS 16.4, *) {
            safeAreaRegions = []
        }
    }

    override var prefersStatusBarHidden: Bool { true }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
}

@objc(VLMDesktopFactory)
public class DesktopFactory: NSObject {
    @objc public static func makeRootViewController() -> UIViewController {
        DesktopHostingController(rootView: ContentView())
    }
}
