//
//  FileViewerView.swift
//  Velum
//
//  专用"文件查看窗口"。
//
//  与 PreviewerView 的区别：
//  - 无侧边栏、无地址栏、无侧栏切换按钮
//  - 只显示文件内容（复用 PreviewRendererView 渲染引擎）
//  - 标题栏由 DesktopWindow 统一提供（Trinity + 文件名）
//  - 由桌面双击 / 右键"打开"调用，contextPath 即文件路径
//
//  这样最大化/窗口化切换时 PreviewerViewModel 的状态得以保留，
//  同时保留与 PreviewerView 相同的渲染能力。
//

import SwiftUI

struct FileViewerView: View {
    /// 要查看的 fakefs 文件路径。
    let path: String

    @StateObject private var vm = PreviewerViewModel()

    var body: some View {
        VStack(spacing: 0) {
            PreviewRendererView(state: vm.previewState)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.05))
        }
        .background(Color.clear)
        .task(id: path) {
            guard !path.isEmpty else { return }
            if vm.addressText != path {
                await vm.loadFromPath(path)
            }
        }
    }
}
