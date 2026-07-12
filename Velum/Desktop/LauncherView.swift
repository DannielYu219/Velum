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
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .liquidGlass(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .frame(width: 72, height: 72)
                    Image(systemName: app.systemImage)
                        .font(.title2)
                        .foregroundStyle(.primary)
                }
                Text(app.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    LauncherView()
        .background(Color.black.opacity(0.4))
}
