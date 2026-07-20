//
//  AppHostView.swift
//  Velum
//
//  Phase 2.4: Renders the frontmost app's content inside a Liquid Glass window.
//  Terminal → TerminalView (Storyboard-backed), others → placeholder.
//

import SwiftUI

struct AppHostView: View {
    let app: VelumApp
    var contextPath: String?
    var onClose: () -> Void = {}
    var onMinimize: () -> Void = {}
    var onZoom: () -> Void = {}
    var onFocus: () -> Void = {}
    var onDrag: (CGPoint) -> Void = { _ in }
    var onDragChanged: (CGPoint) -> Void = { _ in }
    var isMaximized: Bool = false
    var position: CGPoint = .zero

    init(
        app: VelumApp,
        contextPath: String? = nil,
        onClose: @escaping () -> Void = {},
        onMinimize: @escaping () -> Void = {},
        onZoom: @escaping () -> Void = {},
        onFocus: @escaping () -> Void = {},
        onDrag: @escaping (CGPoint) -> Void = { _ in },
        onDragChanged: @escaping (CGPoint) -> Void = { _ in },
        isMaximized: Bool = false,
        position: CGPoint = .zero
    ) {
        self.app = app
        self.contextPath = contextPath
        self.onClose = onClose
        self.onMinimize = onMinimize
        self.onZoom = onZoom
        self.onFocus = onFocus
        self.onDrag = onDrag
        self.onDragChanged = onDragChanged
        self.isMaximized = isMaximized
        self.position = position
    }

    var body: some View {
        switch app {
        case .launcher:
            EmptyView()
        case .terminal:
            TerminalView()
        case .files:
            FilesView(initialPath: contextPath ?? "/")
        case .browser:
            BrowserView(
                onClose: onClose,
                onMinimize: onMinimize,
                onZoom: onZoom,
                onFocus: onFocus,
                onDrag: onDrag,
                onDragChanged: onDragChanged,
                isMaximized: isMaximized,
                position: position
            )
        case .settings:
            SettingsView()
        case .about:
            AboutAppView()
        case .agent:
            AgentView()
        case .skillstore:
            SkillStoreView()
        case .previewer:
            PreviewerView(
                onClose: onClose,
                onMinimize: onMinimize,
                onZoom: onZoom,
                onFocus: onFocus,
                onDrag: onDrag,
                onDragChanged: onDragChanged,
                isMaximized: isMaximized,
                position: position,
                initialPath: contextPath
            )
        case .viewer:
            // 专用文件查看窗口：无侧边栏、无地址栏，仅显示文件内容
            FileViewerView(path: contextPath ?? "")
        }
    }
}

private struct PlaceholderAppView: View {
    let app: VelumApp
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: app.systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// About app — shown when the user opens "About" from the dock/launcher.
/// 内容与 Settings 的"关于"页共用 `AboutContentView`（见 WindowChrome.swift）。
private struct AboutAppView: View {
    var body: some View {
        AboutContentView()
    }
}
