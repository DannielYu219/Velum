//
//  AppInstallerSheets.swift
//  Velum
//
//  安装器配套弹层：App 详情（权限 / 运行方式 / 沙箱路径）+ manifest.json 手动导入。
//

import SwiftUI

// MARK: - App 详情

struct AppDetailSheet: View {
    let manifest: ThirdPartyAppManifest
    let isInstalled: Bool
    let onInstall: () async -> Void
    let onUninstall: () -> Void
    let onOpen: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var working = false

    var body: some View {
        NavigationStack {
            List {
                // 头部
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                            Image(systemName: manifest.icon)
                                .font(.system(size: 30))
                                .foregroundStyle(.tint)
                        }
                        .frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(manifest.name)
                                .font(.title3.weight(.bold))
                            Text(manifest.form.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tint)
                            Text(manifest.author.isEmpty ? manifest.id : manifest.author)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                // 形态说明
                Section("形态") {
                    Text(manifest.form.blurb)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                // 元信息
                Section("信息") {
                    infoRow("标识符", manifest.id, mono: true)
                    infoRow("版本", manifest.version)
                    infoRow("分类", manifest.category)
                    infoRow("沙箱", manifest.sandboxRoot, mono: true)
                }

                // 运行方式
                Section("运行方式") {
                    switch manifest.form {
                    case .h5Package:
                        infoRow("入口", manifest.runtime.entry, mono: true)
                    case .elfBridge:
                        infoRow("命令", manifest.runtime.command ?? "（未设置）", mono: true)
                        infoRow("界面", manifest.runtime.entry, mono: true)
                    case .webService:
                        if let url = manifest.runtime.url, !url.isEmpty {
                            infoRow("URL", url, mono: true)
                        } else {
                            infoRow("命令", manifest.runtime.command ?? "（未设置）", mono: true)
                            infoRow("端口", "\(manifest.runtime.port)")
                        }
                    }
                }

                // 权限
                Section {
                    if manifest.permissions.isEmpty {
                        Text("不申请任何系统权限")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(manifest.permissions, id: \.self) { perm in
                            HStack(spacing: 10) {
                                Image(systemName: permIcon(perm))
                                    .foregroundStyle(.tint)
                                    .frame(width: 22)
                                Text(permLabel(perm))
                                Spacer()
                                Text(perm)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                } header: {
                    Text("权限")
                } footer: {
                    Text("权限在运行时由 window.velum JS 桥逐项校验，未声明的调用会被拒绝。")
                        .font(.caption2)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .navigationTitle("App 详情")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { actionBar }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            if isInstalled {
                Button(role: .destructive) {
                    onUninstall()
                    dismiss()
                } label: {
                    Text("卸载")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.15))
                        .foregroundStyle(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                Button(action: onOpen) {
                    Text("打开")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    Task {
                        working = true
                        await onInstall()
                        working = false
                        dismiss()
                    }
                } label: {
                    Group {
                        if working {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("获取")
                                .font(.body.weight(.bold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(working)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func infoRow(_ key: String, _ value: String, mono: Bool = false) -> some View {
        HStack {
            Text(key)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(mono ? .caption.monospaced() : .body)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func permLabel(_ p: String) -> String {
        switch p {
        case "clipboard": return "剪贴板读写"
        case "notify":    return "发送通知"
        case "exec":      return "执行 Linux 命令"
        case "location":  return "位置信息"
        case "photos":    return "照片库"
        case "camera":    return "相机"
        case "lan":       return "局域网访问"
        case "hostfs-ro": return "宿主文件（只读）"
        default:          return p
        }
    }

    private func permIcon(_ p: String) -> String {
        switch p {
        case "clipboard": return "doc.on.clipboard"
        case "notify":    return "bell.badge"
        case "exec":      return "terminal"
        case "location":  return "location"
        case "photos":    return "photo"
        case "camera":    return "camera"
        case "lan":       return "network"
        case "hostfs-ro": return "externaldrive"
        default:          return "key"
        }
    }
}

