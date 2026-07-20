//
//  LauncherView.swift
//  Velum
//
//  Phase 2.2: App launcher grid.
//  Shows all available apps; tapping launches via WindowManager.
//  Glass surface reuses the same Liquid Glass / blur compat layer.
//

import SwiftUI

struct LauncherView: View {
    @ObservedObject private var wm = WindowManager.shared
    @ObservedObject private var registry = AppRegistry.shared

    var body: some View {
        VStack(spacing: 24) {
            Text("Apps")
                .font(.title2.bold())
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 24)], spacing: 24) {
                // Launcher itself is not shown in the app grid — it's a dock-only entry.
                ForEach(VelumApp.allCases.filter { !$0.isLauncher }) { app in
                    LauncherIcon(app: app)
                }
            }

            // 第三方 App（三种形态：ELF 桥接 / Web 服务 / H5 包）
            if !registry.installed.isEmpty {
                Divider().background(Color.white.opacity(0.1))
                VStack(spacing: 14) {
                    Text("第三方 App")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 24)], spacing: 24) {
                        ForEach(registry.installed) { manifest in
                            ThirdPartyLauncherIcon(manifest: manifest)
                        }
                    }
                }
            }
        }
        .padding(32)
        .liquidGlass(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .frame(maxWidth: 480)
    }
}

private struct LauncherIcon: View {
    let app: VelumApp
    @ObservedObject private var wm = WindowManager.shared

    var body: some View {
        Button {
            wm.open(app)
            VelumControl.shared.perform(.launchApp(AppManifest(name: app.rawValue)))
        } label: {
            VStack(spacing: 10) {
                ZStack {
                    GlassSurface(.regular, in: Circle())
                        .frame(width: 68, height: 68)
                        .clipped()
                    Image(systemName: app.systemImage)
                        .imageScale(.large)
                        .font(.title)
                }
                Text(app.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// 第三方 App 启动器图标（点开经 WindowManager.openThirdParty → ThirdPartyAppHost）。
private struct ThirdPartyLauncherIcon: View {
    let manifest: ThirdPartyAppManifest
    @ObservedObject private var wm = WindowManager.shared

    var body: some View {
        Button {
            wm.openThirdParty(id: manifest.id)
            withAnimation(WindowMotion.launcher) { wm.showLauncher = false }
        } label: {
            VStack(spacing: 10) {
                ZStack {
                    GlassSurface(.regular, in: Circle())
                        .frame(width: 68, height: 68)
                        .clipped()
                    Image(systemName: manifest.icon)
                        .imageScale(.large)
                        .font(.title)
                }
                Text(manifest.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(manifest.form.displayName)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    LauncherView()
        .background(Color.black.opacity(0.4))
}
