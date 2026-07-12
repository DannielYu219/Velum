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

    init(app: VelumApp, contextPath: String? = nil) {
        self.app = app
        self.contextPath = contextPath
    }

    var body: some View {
        switch app {
        case .launcher:
            // Launcher never opens a window — it's a dock-only entry.
            EmptyView()
        case .terminal:
            TerminalView()
        case .files:
            FilesView(initialPath: contextPath ?? "/")
        case .settings:
            SettingsView()
        case .about:
            AboutAppView()
        case .agent:
            AgentView()
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
private struct AboutAppView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.tint)

                Text("Velum")
                    .font(.largeTitle.bold())

                Text("iOS 上的 Linux 桌面环境")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    infoRow("版本", "1.0 (Phase 7)")
                    infoRow("内核", "iSH ARM64")
                    infoRow("桌面", "SwiftUI + Liquid Glass")
                    infoRow("兼容", "iOS 16+")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()

                Text("基于 iSH 开源项目，以 SwiftUI 重新构想的 iOS Linux 桌面。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding()
        }
        .background(Color.clear)
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }
}
