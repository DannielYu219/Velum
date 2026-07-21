//
//  LauncherView.swift
//  Velum
//
//  全屏启动台（Launchpad 风格）：8 列大图标网格，可纵向滚动。
//  内建 App 与第三方 App 同场陈列；底部常驻"安装器"入口。
//  点击空白区域关闭（由 ContentView 的透明遮罩处理）。
//

import SwiftUI

struct LauncherView: View {
    @ObservedObject private var wm = WindowManager.shared
    @ObservedObject private var registry = AppRegistry.shared

    /// 8 列固定网格（用户要求 8×6 可见、超出滚动）。
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 8)

    var body: some View {
        ZStack {
            // 点击空白区域关闭（覆盖 ContentView 的透明关闭层）。
            launcherBackground
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(WindowMotion.launcher) { wm.showLauncher = false }
                }

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        VStack(spacing: 0) {
            // 顶部标题
            HStack(spacing: 10) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                Text("启动台")
                    .font(.title2.weight(.bold))
                Spacer()
                Text("\(builtinApps.count + registry.installed.count) 个 App")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 40)
            .padding(.top, 28)
            .padding(.bottom, 16)

            // 可滚动网格
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 28) {
                    // ── 系统 App ──
                    sectionHeader("系统", count: builtinApps.count)
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(builtinApps) { app in
                            LauncherIcon(app: app)
                        }
                        // 安装器入口（归入系统区末尾）
                        InstallerEntryIcon()
                    }

                    // ── 第三方 App ──
                    if !registry.installed.isEmpty {
                        sectionHeader("第三方", count: registry.installed.count)
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(registry.installed) { manifest in
                                ThirdPartyLauncherIcon(manifest: manifest)
                            }
                        }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 36)
            }
        }
    }

    private var builtinApps: [VelumApp] {
        VelumApp.allCases.filter { !$0.isLauncher }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())
            Spacer()
        }
    }

    /// 深色模糊背景 + 轻微渐变，让启动台覆盖桌面时仍有层次感。
    private var launcherBackground: some View {
        ZStack {
            Color.black.opacity(0.55)
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.08, blue: 0.14).opacity(0.85),
                         Color(red: 0.10, green: 0.13, blue: 0.22).opacity(0.75)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .background(.ultraThinMaterial)
    }
}

// MARK: - 内建 App 图标

private struct LauncherIcon: View {
    let app: VelumApp
    @ObservedObject private var wm = WindowManager.shared
    @State private var hovering = false

    var body: some View {
        Button {
            wm.open(app)
            VelumControl.shared.perform(.launchApp(AppManifest(name: app.rawValue)))
            dismiss()
        } label: {
            VStack(spacing: 10) {
                ZStack {
                    GlassSurface(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .frame(width: 76, height: 76)
                        .clipped()
                    Image(systemName: app.systemImage)
                        .font(.system(size: 30))
                        .foregroundStyle(.primary)
                }
                .scaleEffect(hovering ? 1.08 : 1)
                .shadow(color: .black.opacity(hovering ? 0.35 : 0.15), radius: hovering ? 14 : 6, y: 4)

                Text(app.displayName)
                    .font(.caption)
                    .foregroundStyle(hovering ? .primary : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(WindowMotion.micro, value: hovering)
    }

    private func dismiss() {
        withAnimation(WindowMotion.launcher) { wm.showLauncher = false }
    }
}

// MARK: - 第三方 App 图标

private struct ThirdPartyLauncherIcon: View {
    let manifest: ThirdPartyAppManifest
    @ObservedObject private var wm = WindowManager.shared
    @State private var hovering = false

    var body: some View {
        Button {
            wm.openThirdParty(id: manifest.id)
            withAnimation(WindowMotion.launcher) { wm.showLauncher = false }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    GlassSurface(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .frame(width: 76, height: 76)
                        .clipped()
                    VStack(spacing: 2) {
                        Image(systemName: manifest.icon)
                            .font(.system(size: 26))
                        Text(manifest.form.rawValue.prefix(3).uppercased())
                            .font(.system(size: 7, weight: .heavy, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .scaleEffect(hovering ? 1.08 : 1)
                .shadow(color: .black.opacity(hovering ? 0.35 : 0.15), radius: hovering ? 14 : 6, y: 4)

                VStack(spacing: 2) {
                    Text(manifest.name)
                        .font(.caption)
                        .foregroundStyle(hovering ? .primary : .secondary)
                        .lineLimit(1)
                    Text(manifest.form.displayName)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(WindowMotion.micro, value: hovering)
    }
}

// MARK: - 安装器入口

/// 启动台内常驻的"安装器"快捷入口 — 打开安装器窗口。
private struct InstallerEntryIcon: View {
    @ObservedObject private var wm = WindowManager.shared
    @State private var hovering = false

    var body: some View {
        Button {
            wm.open(.installer)
            withAnimation(WindowMotion.launcher) { wm.showLauncher = false }
        } label: {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.2, green: 0.5, blue: 1.0).opacity(0.35),
                                         Color(red: 0.35, green: 0.7, blue: 1.0).opacity(0.15)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                        )
                        .frame(width: 76, height: 76)
                    Image(systemName: "arrow.down.app.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Color(red: 0.45, green: 0.75, blue: 1.0))
                }
                .scaleEffect(hovering ? 1.08 : 1)
                .shadow(color: Color(red: 0.3, green: 0.6, blue: 1.0).opacity(hovering ? 0.4 : 0.15),
                        radius: hovering ? 16 : 8, y: 4)

                Text("安装器")
                    .font(.caption)
                    .foregroundStyle(hovering ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(WindowMotion.micro, value: hovering)
    }
}

#Preview {
    LauncherView()
}
