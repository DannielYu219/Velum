//
//  WindowManager.swift
//  Velum
//
//  Phase 2.4: Window / app-instance tracking.
//  Pure data model — UI lives in Dock / LauncherView / ContentView.
//
//  Phase 3+: Multi-window support — stackable, draggable, resizable, maximizable.
//

import SwiftUI

// MARK: - Motion tokens

/// 全桌面统一的动效令牌。
enum WindowMotion {
    static let open = Animation.spring(response: 0.5, dampingFraction: 0.75)
    static let launcher = Animation.spring(response: 0.35, dampingFraction: 0.8)
    static let close = Animation.easeInOut(duration: 0.25)
    static let minimize = Animation.spring(response: 0.45, dampingFraction: 0.8)
    static let maximize = Animation.spring(response: 0.35, dampingFraction: 0.8)
    static let micro = Animation.easeInOut(duration: 0.2)
}

/// Identifiers for the built-in apps that can be launched from the dock/launcher.
public enum VelumApp: String, CaseIterable, Identifiable {
    case launcher
    case terminal
    case files
    case browser
    case settings
    case about
    case agent
    case skillstore
    case previewer
    case viewer

    public var id: String { rawValue }

    /// Launcher is a special entry — it opens the app grid overlay, not a window.
    public var isLauncher: Bool { self == .launcher }

    public var displayName: String {
        switch self {
        case .launcher:  return "Apps"
        case .terminal:  return "Terminal"
        case .files:     return "Files"
        case .browser:   return "Browser"
        case .settings:  return "Settings"
        case .about:     return "About"
        case .agent:     return "Agent"
        case .skillstore: return "Skills"
        case .previewer: return "Previewer"
        case .viewer:    return "Viewer"
        }
    }

    public var systemImage: String {
        switch self {
        case .launcher:  return "square.grid.2x2.fill"
        case .terminal:  return "terminal.fill"
        case .files:     return "folder.fill"
        case .browser:   return "safari.fill"
        case .settings:  return "gearshape.fill"
        case .about:     return "info.circle.fill"
        case .agent:     return "bubble.left.and.text.bubble.right.fill"
        case .skillstore: return "sparkles.rectangle.stack.fill"
        case .previewer: return "eye.fill"
        case .viewer:    return "doc.text.fill"
        }
    }

    public var shortcutKey: String? {
        switch self {
        case .launcher:  return nil  // ⌘+L is the global shortcut
        case .terminal:  return "t"
        case .files:     return "f"
        case .browser:   return "b"
        case .settings:  return ","
        case .about:     return "i"
        case .agent:     return "a"
        case .skillstore: return "k"
        case .previewer: return "p"
        case .viewer:    return nil
        }
    }
}

/// A running app instance with window geometry.
public struct AppWindow: Identifiable {
    public let id = UUID()
    public let app: VelumApp
    public var isMinimized: Bool = false
    public var isMaximized: Bool = false
    /// Top-left corner of the window, in screen coordinates.
    public var position: CGPoint
    /// Window size (ignored when maximized — fills the screen).
    public var size: CGSize
    /// Optional context path passed by Agent (e.g. "/etc" for Files to navigate to).
    public var contextPath: String?
    /// 第三方 App id（非 nil 时窗口内容由 ThirdPartyAppHost 渲染，忽略 `app` 的内建分发）。
    public var thirdPartyId: String?

    public init(
        app: VelumApp,
        position: CGPoint = CGPoint(x: 200, y: 150),
        size: CGSize = CGSize(width: 1000, height: 750),
        contextPath: String? = nil,
        thirdPartyId: String? = nil
    ) {
        self.app = app
        self.position = position
        self.size = size
        self.contextPath = contextPath
        self.thirdPartyId = thirdPartyId
    }
}

/// MainActor singleton tracking open windows. SwiftUI views observe via `@ObservedObject`.
@MainActor
public final class WindowManager: ObservableObject {

    public static let shared = WindowManager()

    @Published public private(set) var windows: [AppWindow] = []
    @Published public var frontmostID: UUID?
    /// Launcher overlay visibility — shared so both Dock and ContentView can toggle it.
    @Published public var showLauncher: Bool = false

    private init() {}

    // MARK: Screen / Bounds helpers

    /// 与 SwiftUI 桌面根 GeometryReader 同步的画布尺寸。
    /// ContentView 在布局变化时调用 updateCanvasSize；clamp 一律以它为准。
    @Published public private(set) var canvasSize: CGSize = WindowManager.fallbackScreenSize

    private static var fallbackScreenSize: CGSize {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        if let scene,
           let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
            return window.bounds.size
        }
        return UIScreen.main.bounds.size
    }

    /// 桌面布局坐标系（与 ContentView 画布一致）。
    public static var screenBounds: CGRect {
        let size = WindowManager.shared.canvasSize
        if size.width > 1, size.height > 1 {
            return CGRect(origin: .zero, size: size)
        }
        return CGRect(origin: .zero, size: fallbackScreenSize)
    }

    /// 最小窗口尺寸；小屏时会自动收缩到不超过画布。
    public static let minimumWindowSize = CGSize(width: 320, height: 240)

    /// 将尺寸严格限制在画布内（完整可见，不允许超出屏幕）。
    public static func clamp(size: CGSize, in bounds: CGRect) -> CGSize {
        let maxW = max(1, bounds.width)
        let maxH = max(1, bounds.height)
        let minW = min(minimumWindowSize.width, maxW)
        let minH = min(minimumWindowSize.height, maxH)
        return CGSize(
            width: min(max(size.width, minW), maxW),
            height: min(max(size.height, minH), maxH)
        )
    }

    /// 将尺寸严格限制在当前桌面画布内。
    public static func clamp(size: CGSize) -> CGSize {
        clamp(size: size, in: screenBounds)
    }

    /// 将左上角位置限制为：窗口矩形完整落在 bounds 内。
    public static func clamp(position: CGPoint, size: CGSize, in bounds: CGRect) -> CGPoint {
        let fitted = clamp(size: size, in: bounds)
        let maxX = max(bounds.minX, bounds.maxX - fitted.width)
        let maxY = max(bounds.minY, bounds.maxY - fitted.height)
        let x = min(max(position.x, bounds.minX), maxX)
        let y = min(max(position.y, bounds.minY), maxY)
        return CGPoint(x: x, y: y)
    }

    /// 将左上角位置限制为：窗口矩形完整落在当前桌面画布内。
    public static func clamp(position: CGPoint, size: CGSize) -> CGPoint {
        clamp(position: position, size: size, in: screenBounds)
    }

    /// ContentView 在画布几何变化时同步；会把已有窗口重新夹回屏幕。
    public func updateCanvasSize(_ size: CGSize) {
        // Canvas size is purely whatever SwiftUI GeometryReader measured.
        guard size.width.isFinite, size.height.isFinite else { return }
        guard size.width > 1, size.height > 1 else { return }
        // Reject pathological infinity-like values from bad layout parents
        guard size.width < 100_000, size.height < 100_000 else { return }
        let rounded = CGSize(
            width: size.width.rounded(.towardZero),
            height: size.height.rounded(.towardZero)
        )
        guard rounded != canvasSize else { return }
        canvasSize = rounded
        reclampAllWindows()
    }

    /// 保证所有非最大化窗口完全在画布内（最大化忽略 position/size）。
    private func reclampAllWindows() {
        let bounds = Self.screenBounds
        for i in windows.indices {
            let fitted = Self.clamp(size: windows[i].size, in: bounds)
            windows[i].size = fitted
            windows[i].position = Self.clamp(position: windows[i].position, size: fitted, in: bounds)
        }
    }

    // MARK: Open / Close

    @discardableResult
    public func open(_ app: VelumApp, contextPath: String? = nil) -> AppWindow {
        // 居中放置，多窗口时略微 cascade 偏移；矩形必须完整落在画布内。
        let screen = Self.screenBounds
        let preferred = CGSize(
            width: min(1000, screen.width * 0.86),
            height: min(750, screen.height * 0.78)
        )
        let baseSize = Self.clamp(size: preferred, in: screen)
        let cascade = CGFloat(windows.count * 28)
        let desiredX = max(0, (screen.width - baseSize.width) / 2 + cascade)
        let desiredY = max(0, (screen.height - baseSize.height) / 2 + cascade)
        let pos = Self.clamp(
            position: CGPoint(x: desiredX, y: desiredY),
            size: baseSize,
            in: screen
        )
        let win = AppWindow(
            app: app,
            position: pos,
            size: baseSize,
            contextPath: contextPath
        )
        // 弹性弹出动画（从 Dock 位置放大）
        withAnimation(WindowMotion.open) {
            windows.append(win)
            frontmostID = win.id
        }
        return win
    }

    /// 打开一个第三方 App 窗口（三种形态由 ThirdPartyAppHost 按 manifest 分发）。
    @discardableResult
    public func openThirdParty(id: String, contextPath: String? = nil) -> AppWindow {
        // 用 .launcher 作占位（第三方 App 不属于内建枚举）；thirdPartyId 驱动实际内容。
        var win = open(.launcher, contextPath: contextPath)
        if let idx = windows.firstIndex(where: { $0.id == win.id }) {
            windows[idx].thirdPartyId = id
            win = windows[idx]
        }
        return win
    }

    public func close(_ id: UUID) {
        // 快速缩小淡出
        withAnimation(WindowMotion.close) {
            windows.removeAll { $0.id == id }
            if frontmostID == id {
                frontmostID = windows.last?.id
            }
        }
    }

    // MARK: Focus / Z-order

    public func focus(_ id: UUID) {
        guard windows.contains(where: { $0.id == id }) else { return }
        frontmostID = id
        // Move to end of array (top of z-order in ZStack)
        guard let idx = windows.firstIndex(where: { $0.id == id }) else { return }
        if idx == windows.count - 1 { return } // already on top
        let win = windows.remove(at: idx)
        windows.append(win)
    }

    // MARK: Minimize / Maximize

    public func toggleMinimize(_ id: UUID) {
        guard let idx = windows.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(WindowMotion.minimize) {
            windows[idx].isMinimized.toggle()
            // If we just minimized the frontmost, switch focus to the next visible window.
            if windows[idx].isMinimized && frontmostID == id {
                frontmostID = windows.last(where: { !$0.isMinimized })?.id
            }
        }
    }

    /// 恢复某 app 最新的最小化窗口（从 dock 图标点击恢复）。
    public func restore(_ app: VelumApp) {
        guard let idx = windows.firstIndex(where: { $0.app == app && $0.isMinimized }) else { return }
        withAnimation(WindowMotion.open) {
            windows[idx].isMinimized = false
            // 移到顶层（ZStack 末尾）并聚焦
            let win = windows.remove(at: idx)
            windows.append(win)
            frontmostID = win.id
        }
    }

    /// 该 app 是否有最小化的窗口（用于 Dock 图标高亮）。
    public func hasMinimizedWindow(_ app: VelumApp) -> Bool {
        windows.contains { $0.app == app && $0.isMinimized }
    }

    public func toggleMaximize(_ id: UUID) {
        guard let idx = windows.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(WindowMotion.maximize) {
            windows[idx].isMaximized.toggle()
        }
    }

    // MARK: Geometry updates (no animation — called during drag/resize)

    public func updatePosition(_ id: UUID, position: CGPoint) {
        guard let idx = windows.firstIndex(where: { $0.id == id }) else { return }
        let size = windows[idx].size
        windows[idx].position = Self.clamp(position: position, size: size)
    }

    public func updateSize(_ id: UUID, size: CGSize) {
        guard let idx = windows.firstIndex(where: { $0.id == id }) else { return }
        let fitted = Self.clamp(size: size)
        windows[idx].size = fitted
        // 放大到右/下边界外时，回推左上角，保证完整仍在屏幕内
        windows[idx].position = Self.clamp(position: windows[idx].position, size: fitted)
    }

    // MARK: Convenience

    public var frontmost: AppWindow? {
        guard let id = frontmostID else { return nil }
        return windows.first { $0.id == id }
    }

    /// True when the frontmost window is visible (not minimized) AND maximized.
    /// A minimized maximized window should NOT keep TopBar/Dock hidden.
    public var hasMaximizedFrontmost: Bool {
        guard let front = frontmost, !front.isMinimized else { return false }
        return front.isMaximized
    }
}
