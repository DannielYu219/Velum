//
//  WindowChrome.swift
//  Velum
//
//  共享窗口装饰层 —— 统一各内建 App 的窗口头部元素与动效，消除重复实现。
//
//  背景：此前 Files / Previewer / Browser 各自实现了一套地址栏、工具按钮，
//  Browser 还自带一套与全局样式不一致的 Trinity 红绿灯；About 内容在
//  AppHostView 与 SettingsView 各写了一份；分隔线透明度、动画 spring 参数
//  也散落各处。本文件把这些收敛为单一来源，供各 App 复用，保证设计统一。
//
//  组件：
//   - WindowMotion       统一动效令牌（开 / 关 / 最小化 / 启动器 / 微交互）
//   - ChromeMetric       窗口装饰尺寸常量
//   - WindowTrinity      macOS 风格红绿灯（关闭 / 最小化 / 最大化）
//   - ChromeToolButton   28×28 工具栏图标按钮
//   - ChromeAddressField 胶囊地址 / 搜索栏（可选前置安全图标 + 清除按钮）
//   - ChromeDivider      统一分隔线
//   - AboutContentView   "关于 Velum" 内容（独立 About App 与 Settings 共用）
//

import SwiftUI

// MARK: - Metrics

/// 窗口装饰的统一尺寸。
enum ChromeMetric {
    static let toolbarButton: CGFloat = 28
    static let trinityButton: CGFloat = 24
    static let addressIconFrame: CGFloat = 14
}

// MARK: - Trinity (window controls)

/// macOS 风格红绿灯：关闭（红）/ 最小化（黄）/ 最大化（绿）。
/// 全局唯一实现 —— DesktopWindow 与 Browser 自定义标题栏都复用它，保证视觉一致。
/// 绿键悬停通过 `onGreenHover` 上报；分屏面板由宿主窗口在顶层 overlay
/// 渲染（保证命中测试不被内容层拦截）。
struct WindowTrinity: View {
    let onClose: () -> Void
    let onMinimize: () -> Void
    let onZoom: () -> Void
    var onGreenHover: (Bool) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 0) {
            TrinityButton(tint: .red, symbol: "xmark", action: onClose)
                .padding(.trailing, 4)
            TrinityButton(tint: .yellow, symbol: "minus", action: onMinimize)
                .padding(.horizontal, 4)
            GreenButtonWithSnap(onZoom: onZoom, onHoverChanged: onGreenHover)
                .padding(.leading, 4)
        }
        .padding(8)
    }
}

private struct TrinityButton: View {
    let tint: Color
    let symbol: String
    let action: () -> Void

    var body: some View {
        Image(systemName: symbol)
            .imageScale(.large)
            .symbolRenderingMode(.monochrome)
            .font(.system(.footnote, weight: .black))
            .foregroundStyle(tint)
            .frame(width: ChromeMetric.trinityButton, height: ChromeMetric.trinityButton)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

// MARK: - 分屏预设（macOS 标准网格面板）

/// 分屏预设：单位坐标（0...1）区域矩形。
struct SnapPreset: Identifiable {
    let id: String
    let unit: CGRect

    static let moveResize: [SnapPreset] = [
        .init(id: "left",  unit: CGRect(x: 0,   y: 0,   width: 0.5, height: 1)),
        .init(id: "right", unit: CGRect(x: 0.5, y: 0,   width: 0.5, height: 1)),
        .init(id: "top",   unit: CGRect(x: 0,   y: 0,   width: 1,   height: 0.5)),
        .init(id: "bottom",unit: CGRect(x: 0,   y: 0.5, width: 1,   height: 0.5)),
    ]
    static let fillArrange: [SnapPreset] = [
        .init(id: "tl", unit: CGRect(x: 0,   y: 0,   width: 0.5, height: 0.5)),
        .init(id: "tr", unit: CGRect(x: 0.5, y: 0,   width: 0.5, height: 0.5)),
        .init(id: "bl", unit: CGRect(x: 0,   y: 0.5, width: 0.5, height: 0.5)),
        .init(id: "br", unit: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)),
    ]
}

/// 绿键：点击 = 最大化；悬停状态上报给宿主窗口（面板在宿主顶层渲染）。
private struct GreenButtonWithSnap: View {
    let onZoom: () -> Void
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        TrinityButton(tint: .green, symbol: "square") { onZoom() }
            .onHover(perform: onHoverChanged)
    }
}

/// macOS 标准分屏面板：屏幕缩略图网格，填充块表示窗口落区。
/// 非 private：宿主窗口（DesktopWindow）在顶层 overlay 渲染它。
struct SnapPanel: View {
    let onSelect: (SnapPreset) -> Void
    var onHoverChanged: (Bool) -> Void = { _ in }
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            group("移动与调整大小", SnapPreset.moveResize)
            Divider().opacity(0.3)
            group("填充与排列", SnapPreset.fillArrange)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .onHover(perform: onHoverChanged)
    }

    private func group(_ title: String, _ presets: [SnapPreset]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(presets) { preset in
                    SnapThumbnail(unit: preset.unit, highlighted: hovered == preset.id)
                        .onHover { h in hovered = h ? preset.id : nil }
                        .onTapGesture { onSelect(preset) }
                }
            }
        }
    }
}

/// 单个屏幕缩略图：外框 = 屏幕，填充块 = 窗口区域。
private struct SnapThumbnail: View {
    let unit: CGRect
    let highlighted: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(highlighted ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06))
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(highlighted ? Color.accentColor : Color.secondary.opacity(0.7),
                                  lineWidth: 1)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(highlighted ? Color.accentColor : Color.secondary.opacity(0.85))
                    .frame(width: max(4, geo.size.width * unit.width - 3),
                           height: max(3, geo.size.height * unit.height - 3))
                    .offset(x: geo.size.width * unit.minX + 1.5,
                            y: geo.size.height * unit.minY + 1.5)
            }
        }
        .frame(width: 38, height: 26)
        .contentShape(Rectangle())
        .scaleEffect(highlighted ? 1.06 : 1)
        .animation(WindowMotion.micro, value: highlighted)
    }
}

// MARK: - Toolbar button

/// 28×28 工具栏图标按钮。
/// - `isActive`：nil = 普通主色；true = 强调色；false = 弱化主色。
/// - `isEnabled`：false 时禁用并进一步弱化。
struct ChromeToolButton: View {
    let systemName: String
    var isActive: Bool? = nil
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .imageScale(.medium)
                .foregroundStyle(foreground)
                .frame(width: ChromeMetric.toolbarButton, height: ChromeMetric.toolbarButton)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private var foreground: Color {
        if !isEnabled { return Color.secondary.opacity(0.4) }
        switch isActive {
        case .some(true):  return Color.accentColor
        case .some(false): return Color.primary
        case nil:          return Color.primary
        }
    }
}

// MARK: - Address field

/// 胶囊地址 / 搜索栏：可选前置图标（如安全锁 / 文件夹）+ 文本框 + 清除按钮。
/// Files / Previewer / Browser 共用，统一外观与交互。
struct ChromeAddressField: View {
    let placeholder: String
    @Binding var text: String
    var leadingIcon: String? = nil
    var leadingIconColor: Color = .secondary
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            if let leadingIcon {
                Image(systemName: leadingIcon)
                    .imageScale(.small)
                    .foregroundStyle(leadingIconColor)
                    .frame(width: ChromeMetric.addressIconFrame)
            }

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .default))
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
                .submitLabel(.go)
                .onSubmit(onSubmit)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.08))
        .clipShape(Capsule(style: .continuous))
    }
}

// MARK: - Divider

/// 统一分隔线（白色 10% 不透明度）。
struct ChromeDivider: View {
    var body: some View {
        Divider().background(Color.white.opacity(0.1))
    }
}

// MARK: - About content

/// "关于 Velum" 内容。独立的 About App 与 Settings 的"关于"页共用这一份，
/// 避免两处各写一遍。
struct AboutContentView: View {
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
