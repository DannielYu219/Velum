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

/// Identifiers for the built-in apps that can be launched from the dock/launcher.
public enum VelumApp: String, CaseIterable, Identifiable {
    case launcher
    case terminal
    case files
    case settings
    case about
    case agent

    public var id: String { rawValue }

    /// Launcher is a special entry — it opens the app grid overlay, not a window.
    public var isLauncher: Bool { self == .launcher }

    public var displayName: String {
        switch self {
        case .launcher:  return "Apps"
        case .terminal:  return "Terminal"
        case .files:     return "Files"
        case .settings:  return "Settings"
        case .about:     return "About"
        case .agent:     return "Agent"
        }
    }

    public var systemImage: String {
        switch self {
        case .launcher:  return "square.grid.2x2.fill"
        case .terminal:  return "terminal.fill"
        case .files:     return "folder.fill"
        case .settings:  return "gearshape.fill"
        case .about:     return "info.circle.fill"
        case .agent:     return "bubble.left.and.text.bubble.right.fill"
        }
    }

    public var shortcutKey: String? {
        switch self {
        case .launcher:  return nil  // ⌘+L is the global shortcut
        case .terminal:  return "t"
        case .files:     return "f"
        case .settings:  return ","
        case .about:     return "i"
        case .agent:     return "a"
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

    public init(
        app: VelumApp,
        position: CGPoint = CGPoint(x: 200, y: 150),
        size: CGSize = CGSize(width: 1000, height: 750),
        contextPath: String? = nil
    ) {
        self.app = app
        self.position = position
        self.size = size
        self.contextPath = contextPath
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

    // MARK: Open / Close

    @discardableResult
    public func open(_ app: VelumApp, contextPath: String? = nil) -> AppWindow {
        // Multi-instance: always create a new window, cascade position.
        let offset = windows.count * 30
        let win = AppWindow(
            app: app,
            position: CGPoint(x: 200 + offset, y: 150 + offset),
            contextPath: contextPath
        )
        // 弹性弹出动画（从 Dock 位置放大）
        withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
            windows.append(win)
            frontmostID = win.id
        }
        return win
    }

    public func close(_ id: UUID) {
        // 快速缩小淡出
        withAnimation(.easeInOut(duration: 0.25)) {
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
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
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
        withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
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
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            windows[idx].isMaximized.toggle()
        }
    }

    // MARK: Geometry updates (no animation — called during drag/resize)

    public func updatePosition(_ id: UUID, position: CGPoint) {
        guard let idx = windows.firstIndex(where: { $0.id == id }) else { return }
        windows[idx].position = position
    }

    public func updateSize(_ id: UUID, size: CGSize) {
        guard let idx = windows.firstIndex(where: { $0.id == id }) else { return }
        windows[idx].size = size
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
