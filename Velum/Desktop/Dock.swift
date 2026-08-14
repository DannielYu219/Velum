//
//  Dock.swift
//  Velum
//
//  Phase 2.4: Bottom dock — Liquid Glass capsule with app icons.
//
//  [修复 2026-08] 内建图标与第三方 App 图标共用同一套布局数据（Dock.pinnedApps +
//  thirdPartyIDs），最小化落点计算（ContentView.dockIconCenter）也以它为单一来源，
//  修复此前 11 vs 9 图标错位与"最小化第三方窗口无法恢复"的问题。
//

import SwiftUI

struct Dock: View {
    @ObservedObject private var wm = WindowManager.shared
    @ObservedObject private var registry = AppRegistry.shared

    /// Apps pinned to the dock.
    /// .viewer 是瞬时的文件查看窗口，不作为 Dock 常驻入口。
    /// .installer 从启动台进入，不占 Dock 槽位。
    /// 供 Dock 与最小化落点计算共用的单一数据源。
    static let pinnedApps: [VelumApp] = VelumApp.allCases.filter { $0 != .viewer && $0 != .installer }

    /// 已打开第三方 App 的 id（按首次开窗顺序去重）。
    private var thirdPartyIDs: [String] {
        var seen = Set<String>()
        return wm.windows.compactMap { $0.thirdPartyId }.filter { seen.insert($0).inserted }
    }

    /// Dynamic capsule width: iconCount × 76 + 8 (per design spec).
    private var capsuleWidth: CGFloat {
        CGFloat(Self.pinnedApps.count + thirdPartyIDs.count) * 76 + 8
    }

    var body: some View {
        ZStack {
            // dockBG — width adapts to icon count
            GlassSurface(.clear, tint: .clear.opacity(0.06), in: Capsule(style: .continuous))
                .frame(width: capsuleWidth, height: 84)
                .clipped()
                .padding(8)

            // dock icons
            HStack(spacing: 0) {
                ForEach(Self.pinnedApps) { app in
                    DockIcon(app: app)
                        .padding(.horizontal, 4)
                }
                ForEach(thirdPartyIDs, id: \.self) { id in
                    ThirdPartyDockIcon(appId: id)
                        .padding(.horizontal, 4)
                }
            }
        }
    }
}

// MARK: - Dock Icon

private struct DockIcon: View {
    let app: VelumApp
    @ObservedObject private var wm = WindowManager.shared

    /// 该 app 是否有最小化的窗口（用于背景高亮 + 点击恢复）。
    private var hasMinimized: Bool {
        wm.hasMinimizedWindow(app)
    }

    var body: some View {
        Button {
            if app.isLauncher {
                // Toggle launcher overlay directly — no VelumControl indirection.
                withAnimation(WindowMotion.launcher) {
                    wm.showLauncher.toggle()
                }
            } else if hasMinimized {
                // 有最小化窗口 → 恢复
                wm.restore(app)
            } else {
                wm.open(app)
                VelumControl.shared.perform(.launchApp(AppManifest(name: app.rawValue)))
            }
        } label: {
            iconBody(systemImage: app.systemImage, highlighted: hasMinimized)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func iconBody(systemImage: String, highlighted: Bool) -> some View {
        ZStack {
            GlassSurface(.regular, in: Circle())
                .frame(width: 68, height: 68)
                .clipped()
            Circle()
                .fill(Color.white.opacity(highlighted ? 0.25 : 0))
                .frame(width: 68, height: 68)
                .animation(.easeInOut(duration: 0.25), value: highlighted)
            Image(systemName: systemImage)
                .imageScale(.large)
                .font(.title)
        }
    }
}

// MARK: - 第三方 App Dock 图标（可恢复最小化窗口 / 聚焦已开窗口）

private struct ThirdPartyDockIcon: View {
    let appId: String
    @ObservedObject private var wm = WindowManager.shared
    @ObservedObject private var registry = AppRegistry.shared

    private var hasMinimized: Bool {
        wm.windows.contains { $0.thirdPartyId == appId && $0.isMinimized }
    }

    private var frontmostWindow: AppWindow? {
        wm.windows.first { $0.thirdPartyId == appId && !$0.isMinimized }
    }

    var body: some View {
        Button {
            if hasMinimized {
                wm.restoreThirdParty(appId)
            } else if let win = frontmostWindow {
                wm.focus(win.id)
            } else {
                registry.open(appId)
            }
        } label: {
            ZStack {
                GlassSurface(.regular, in: Circle())
                    .frame(width: 68, height: 68)
                    .clipped()
                Circle()
                    .fill(Color.white.opacity(hasMinimized ? 0.25 : 0))
                    .frame(width: 68, height: 68)
                    .animation(.easeInOut(duration: 0.25), value: hasMinimized)
                Image(systemName: registry.app(appId)?.icon ?? "app.dashed")
                    .imageScale(.large)
                    .font(.title)
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    Dock()
        .background(Color.black.opacity(0.4))
}
