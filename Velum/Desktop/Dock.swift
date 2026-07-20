//
//  Dock.swift
//  Velum
//
//  Phase 2.4: Bottom dock — Liquid Glass capsule with app icons.
//
//  Strictly follows prototype (~/Downloads/Velum Desktop UI.rtf):
//    ZStack {
//      Capsule(.continuous).hidden().glassEffect(.clear.tint(.clear.opacity(0.06)),
//                                                 in: .capsule(.continuous))
//        .frame(width: 464, height: 84).clipped().padding(8)
//      HStack(spacing: 0) {
//        ForEach(0..<5) { _ in
//          ZStack {
//            Circle().hidden().glassEffect(.regular, in: .circle)
//              .frame(width: 68, height: 68).clipped()
//            Image(systemName: "paperplane").imageScale(.large).font(.title)
//          }
//          .padding(.horizontal, 4)
//        }
//      }
//    }
//
//  `GlassSurface` is the compat wrapper: on iOS 26+ it renders exactly
//  `shape.hidden().glassEffect(...)`; on iOS < 26 it falls back to a blur fill.
//  No extra layout modifiers are added beyond the prototype.
//

import SwiftUI

struct Dock: View {
    @ObservedObject private var wm = WindowManager.shared

    /// Apps pinned to the dock.
    /// `.viewer` 是瞬时的文件查看窗口，不作为 Dock 常驻入口。
    private let pinned: [VelumApp] = VelumApp.allCases.filter { $0 != .viewer }

    /// Dynamic capsule width: iconCount × 76 + 8 (per design spec).
    private var capsuleWidth: CGFloat {
        CGFloat(pinned.count) * 76 + 8
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
                ForEach(pinned) { app in
                    DockIcon(app: app)
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
            ZStack {
                GlassSurface(.regular, in: Circle())
                    .frame(width: 68, height: 68)
                    .clipped()
                // 最小化指示 — 背景高亮
                Circle()
                    .fill(Color.white.opacity(hasMinimized ? 0.25 : 0))
                    .frame(width: 68, height: 68)
                    .animation(.easeInOut(duration: 0.25), value: hasMinimized)
                Image(systemName: app.systemImage)
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
