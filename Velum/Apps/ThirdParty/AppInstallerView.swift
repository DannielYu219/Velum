//
//  AppInstallerView.swift
//  Velum
//
//  第三方 App 安装器（软件中心）：浏览目录 / 安装 / 卸载 / 查看详情 / 手动导入。
//  设计风格与 SkillStoreView 一致：NavigationStack + insetGrouped List + 透明背景 + sheet 详情。
//
//  三种来源：
//   1. 内建商店目录（AppRegistry.catalog，覆盖三形态示例）
//   2. 手动导入 manifest.json 文本（AppRegistry.installFromJSON）
//   3. 已安装列表（可卸载 / 打开 / 看详情）
//

import SwiftUI
import UniformTypeIdentifiers

struct AppInstallerView: View {
    @ObservedObject private var registry = AppRegistry.shared
    @State private var searchText: String = ""
    @State private var detail: ThirdPartyAppManifest? = nil
    @State private var showVAPPicker = false
    @State private var installing: Set<String> = []
    /// .vap 安装进行中（写入 + 解包 + 落地）。
    @State private var vapWorking = false
    /// 安装结果提示（成功 / 失败）。
    @State private var outcome: InstallOutcome? = nil

    var body: some View {
        NavigationStack {
            List {
                headerBanner

                if !registry.installed.isEmpty {
                    installedSection
                }

                ForEach(catalogGroups, id: \.0) { form, items in
                    catalogSection(form: form, items: items)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .navigationTitle("安装器")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索 App")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showVAPPicker = true
                    } label: {
                        Label("安装 .vap", systemImage: "square.and.arrow.down.on.square")
                    }
                    .disabled(vapWorking)
                }
            }
            .sheet(item: $detail) { manifest in
                AppDetailSheet(
                    manifest: manifest,
                    isInstalled: registry.app(manifest.id) != nil,
                    onInstall: { await install(manifest, tagline: taglineFor(manifest.id)) },
                    onUninstall: { registry.uninstall(manifest.id) },
                    onOpen: {
                        registry.open(manifest.id)
                        detail = nil
                    }
                )
            }
            .fileImporter(
                isPresented: $showVAPPicker,
                allowedContentTypes: [.vapPackage],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { Task { await installVAP(url) } }
                case .failure(let error):
                    outcome = InstallOutcome(success: false, title: "无法选择文件",
                                             message: error.localizedDescription)
                }
            }
            .alert(
                outcome?.title ?? "",
                isPresented: Binding(get: { outcome != nil },
                                     set: { if !$0 { outcome = nil } }),
                presenting: outcome
            ) { _ in
                Button("好", role: .cancel) {}
            } message: { o in
                Text(o.message)
            }
            .overlay {
                if vapWorking { installingHUD }
            }
        }
    }

    // MARK: - .vap 安装

    private func installVAP(_ url: URL) async {
        vapWorking = true
        defer { vapWorking = false }
        do {
            let manifest = try await registry.installVAP(at: url)
            outcome = InstallOutcome(success: true, title: "安装成功",
                                     message: "已安装「\(manifest.name)」（\(manifest.form.displayName)）")
        } catch {
            outcome = InstallOutcome(success: false, title: "安装失败",
                                     message: error.localizedDescription)
        }
    }

    private var installingHUD: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("正在安装 .vap 包…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    // MARK: - 顶部横幅

    private var headerBanner: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                    .frame(width: 52, height: 52)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Velum 软件中心")
                        .font(.headline)
                    Text("安装 .vap 安装包 · ELF 桥接 / Web 服务 / H5 包")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)

            // 导入 .vap 主入口
            Button {
                showVAPPicker = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down.on.square.fill")
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("导入 .vap 安装包")
                            .font(.body.weight(.semibold))
                        Text("从「文件」选择一个 .vap（本质为压缩包）")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .disabled(vapWorking)
        }
    }

    // MARK: - 已安装区

    private var installedSection: some View {
        Section {
            ForEach(filteredInstalled) { manifest in
                InstalledRow(
                    manifest: manifest,
                    onOpen: { registry.open(manifest.id) },
                    onTap: { detail = manifest },
                    onUninstall: { registry.uninstall(manifest.id) }
                )
            }
        } header: {
            sectionHeader(icon: "checkmark.seal.fill", tint: .green,
                          title: "已安装", count: filteredInstalled.count)
        }
    }

    // MARK: - 目录区（按形态分组）

    private func catalogSection(form: AppForm, items: [CatalogItem]) -> some View {
        Section {
            ForEach(items) { item in
                CatalogRow(
                    item: item,
                    isInstalling: installing.contains(item.id),
                    onInstall: { await install(item.manifest, tagline: item.tagline) },
                    onTap: { detail = item.manifest }
                )
            }
        } header: {
            sectionHeader(icon: form.systemImage, tint: .accentColor,
                          title: form.displayName, count: items.count)
        } footer: {
            Text(form.blurb)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func sectionHeader(icon: String, tint: Color, title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint)
            Text(title)
                .font(.caption.weight(.semibold))
            Text("\(count)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 数据

    private var filteredInstalled: [ThirdPartyAppManifest] {
        guard !searchText.isEmpty else { return registry.installed }
        return registry.installed.filter { match($0.name, $0.id) }
    }

    /// 目录中尚未安装的条目，按形态分组，保持 AppForm 的声明顺序。
    private var catalogGroups: [(AppForm, [CatalogItem])] {
        let pending = registry.catalogNotInstalled.filter {
            searchText.isEmpty || match($0.manifest.name, $0.manifest.id)
        }
        return AppForm.allCases.compactMap { form in
            let items = pending.filter { $0.manifest.form == form }
            return items.isEmpty ? nil : (form, items)
        }
    }

    private func match(_ name: String, _ id: String) -> Bool {
        let q = searchText.lowercased()
        return name.lowercased().contains(q) || id.lowercased().contains(q)
    }

    private func taglineFor(_ id: String) -> String {
        AppRegistry.catalog.first { $0.id == id }?.tagline ?? ""
    }

    private func install(_ manifest: ThirdPartyAppManifest, tagline: String) async {
        installing.insert(manifest.id)
        let item = CatalogItem(manifest: manifest, tagline: tagline)
        await registry.installCatalogItem(item)
        installing.remove(manifest.id)
    }
}

// MARK: - 已安装行

private struct InstalledRow: View {
    let manifest: ThirdPartyAppManifest
    let onOpen: () -> Void
    let onTap: () -> Void
    let onUninstall: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                AppIconBadge(icon: manifest.icon, form: manifest.form)
                VStack(alignment: .leading, spacing: 2) {
                    Text(manifest.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text("\(manifest.form.displayName) · v\(manifest.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onOpen) {
                    Text("打开")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.18))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onUninstall) {
                Label("卸载", systemImage: "trash")
            }
        }
    }
}

// MARK: - 目录行

private struct CatalogRow: View {
    let item: CatalogItem
    let isInstalling: Bool
    let onInstall: () async -> Void
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                AppIconBadge(icon: item.manifest.icon, form: item.manifest.form)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.manifest.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(item.tagline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                installButton
            }
        }
        .buttonStyle(.plain)
    }

    private var installButton: some View {
        Button {
            Task { await onInstall() }
        } label: {
            if isInstalling {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 62, height: 28)
            } else {
                Text("获取")
                    .font(.caption.weight(.bold))
                    .frame(width: 62, height: 28)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .disabled(isInstalling)
    }
}

// MARK: - 图标徽章

private struct AppIconBadge: View {
    let icon: String
    let form: AppForm

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.tint)
        }
        .frame(width: 46, height: 46)
    }
}

// MARK: - 安装结果

/// .vap 安装的结果提示（成功 / 失败），用于 alert 呈现。
struct InstallOutcome: Identifiable {
    let id = UUID()
    let success: Bool
    let title: String
    let message: String
}

#Preview {
    AppInstallerView()
        .background(Color.black)
}
