//
//  SettingsView.swift
//  Velum
//
//  Phase 7.1: Settings App — 外观 / 字体 / 光标 / 启动命令 / rootfs / 关于
//  读写 iSH 的 UserPreferences（通过 bridging header 暴露的 Obj-C singleton）。
//

import SwiftUI
import PhotosUI

struct SettingsView: View {
    @ObservedObject private var wallpaper = WallpaperManager.shared
    @State private var showPhotoPicker: Bool = false
    @State private var showFilePicker: Bool = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    var body: some View {
        NavigationStack {
            List {
                wallpaperSection
                appearanceSection
                fontSection
                cursorSection
                keyboardSection
                launchSection
                rootfsSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images)
        .onChange(of: selectedPhotoItem) { newItem in
            guard let item = newItem else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    WallpaperManager.shared.setImage(image)
                }
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result, let data = try? Data(contentsOf: url),
               let image = UIImage(data: data) {
                WallpaperManager.shared.setImage(image)
            }
        }
    }

    // MARK: - Wallpaper

    @ViewBuilder
    private var wallpaperSection: some View {
        Section("桌面壁纸") {
            if let img = wallpaper.customImage {
                HStack {
                    Text("当前壁纸已设置")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 48, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                Button(role: .destructive) {
                    WallpaperManager.shared.clearImage()
                } label: {
                    Label("恢复默认壁纸", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
            }
            Button {
                showPhotoPicker = true
            } label: {
                Label("从相册选取", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(.borderless)
            Button {
                showFilePicker = true
            } label: {
                Label("从文件选取", systemImage: "folder")
            }
            .buttonStyle(.borderless)
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Appearance

    @ViewBuilder
    private var appearanceSection: some View {
        Section("外观") {
            Picker("配色方案", selection: colorSchemeBinding) {
                Text("跟随系统").tag(Int(0))
                Text("始终浅色").tag(Int(1))
                Text("始终深色").tag(Int(2))
            }
            Toggle("隐藏状态栏", isOn: hideStatusBarBinding)
            Toggle("禁止屏幕变暗", isOn: disableDimmingBinding)
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Font

    @ViewBuilder
    private var fontSection: some View {
        Section("字体") {
            HStack {
                Text("字体族")
                Spacer()
                Text(fontFamilyDisplay)
                    .foregroundStyle(.secondary)
            }
            Stepper(value: fontSizeBinding, in: 8...32, step: 1) {
                HStack {
                    Text("字号")
                    Spacer()
                    Text("\(Int(fontSizeBinding.wrappedValue)) pt")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Cursor

    @ViewBuilder
    private var cursorSection: some View {
        Section("光标") {
            Picker("光标样式", selection: cursorStyleBinding) {
                Text("方块").tag(Int(0))
                Text("竖线").tag(Int(1))
                Text("下划线").tag(Int(2))
            }
            Toggle("光标闪烁", isOn: blinkCursorBinding)
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Keyboard

    @ViewBuilder
    private var keyboardSection: some View {
        Section("键盘") {
            Toggle("外接键盘时隐藏扩展键栏", isOn: hideExtraKeysBinding)
            Picker("Caps Lock 映射", selection: capsLockBinding) {
                Text("无").tag(Int(0))
                Text("Control").tag(Int(1))
                Text("Escape").tag(Int(2))
            }
            Picker("Option 键映射", selection: optionBinding) {
                Text("无").tag(Int(0))
                Text("Escape").tag(Int(1))
            }
            Toggle("反引号映射为 Escape", isOn: backtickEscapeBinding)
            Toggle("覆盖 Control+Space", isOn: overrideControlSpaceBinding)
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Launch

    @ViewBuilder
    private var launchSection: some View {
        Section {
            HStack {
                Text("启动命令")
                Spacer()
                Text(launchCommandDisplay)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack {
                Text("Boot 命令")
                Spacer()
                Text(bootCommandDisplay)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack {
                Text("主机名")
                Spacer()
                Text(hostnameDisplay)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } header: {
            Text("启动")
        } footer: {
            Text("修改后下次启动会话生效。")
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Rootfs

    @ViewBuilder
    private var rootfsSection: some View {
        Section("rootfs") {
            NavigationLink {
                RootfsManagementView()
            } label: {
                Label("rootfs 管理", systemImage: "internaldrive")
            }
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - About

    @ViewBuilder
    private var aboutSection: some View {
        Section("关于") {
            HStack {
                Text("版本")
                Spacer()
                Text("Velum 1.0")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("内核")
                Spacer()
                Text("iSH (ARM64)")
                    .foregroundStyle(.secondary)
            }
            NavigationLink {
                AboutView()
            } label: {
                Label("关于 Velum", systemImage: "info.circle")
            }
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Bindings to UserPreferences

    private var colorSchemeBinding: Binding<Int> {
        Binding(
            get: { Int(UserPreferences.shared().colorScheme.rawValue) },
            set: { UserPreferences.shared().colorScheme = ColorScheme(rawValue: $0) ?? .ColorSchemeMatchSystem }
        )
    }

    private var hideStatusBarBinding: Binding<Bool> {
        Binding(
            get: { UserPreferences.shared().hideStatusBar },
            set: { UserPreferences.shared().hideStatusBar = $0 }
        )
    }

    private var disableDimmingBinding: Binding<Bool> {
        Binding(
            get: { UserPreferences.shared().shouldDisableDimming },
            set: { UserPreferences.shared().shouldDisableDimming = $0 }
        )
    }

    private var fontFamilyDisplay: String {
        UserPreferences.shared().fontFamilyUserFacingName
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(
            get: { UserPreferences.shared().fontSize.doubleValue },
            set: { UserPreferences.shared().fontSize = NSNumber(value: $0) }
        )
    }

    private var cursorStyleBinding: Binding<Int> {
        Binding(
            get: { Int(UserPreferences.shared().cursorStyle.rawValue) },
            set: { UserPreferences.shared().cursorStyle = CursorStyle(rawValue: $0) ?? .CursorStyleBlock }
        )
    }

    private var blinkCursorBinding: Binding<Bool> {
        Binding(
            get: { UserPreferences.shared().blinkCursor },
            set: { UserPreferences.shared().blinkCursor = $0 }
        )
    }

    private var hideExtraKeysBinding: Binding<Bool> {
        Binding(
            get: { UserPreferences.shared().hideExtraKeysWithExternalKeyboard },
            set: { UserPreferences.shared().hideExtraKeysWithExternalKeyboard = $0 }
        )
    }

    private var capsLockBinding: Binding<Int> {
        Binding(
            get: { Int(UserPreferences.shared().capsLockMapping.rawValue) },
            set: { UserPreferences.shared().capsLockMapping = CapsLockMapping(rawValue: $0) ?? .CapsLockMapNone }
        )
    }

    private var optionBinding: Binding<Int> {
        Binding(
            get: { Int(UserPreferences.shared().optionMapping.rawValue) },
            set: { UserPreferences.shared().optionMapping = OptionMapping(rawValue: UInt($0)) }
        )
    }

    private var backtickEscapeBinding: Binding<Bool> {
        Binding(
            get: { UserPreferences.shared().backtickMapEscape },
            set: { UserPreferences.shared().backtickMapEscape = $0 }
        )
    }

    private var overrideControlSpaceBinding: Binding<Bool> {
        Binding(
            get: { UserPreferences.shared().overrideControlSpace },
            set: { UserPreferences.shared().overrideControlSpace = $0 }
        )
    }

    private var launchCommandDisplay: String {
        UserPreferences.shared().launchCommand.joined(separator: " ")
    }

    private var bootCommandDisplay: String {
        UserPreferences.shared().bootCommand.joined(separator: " ")
    }

    private var hostnameDisplay: String {
        let host = UserPreferences.shared().hostnameOverride
        return host.isEmpty ? "(默认)" : host
    }
}

// MARK: - Rootfs Management

private struct RootfsManagementView: View {
    @StateObject private var manager = RootfsManager()

    var body: some View {
        List {
            mirrorSection
            updateSection
            backupSection
            backupsListSection
            logSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .navigationTitle("rootfs 管理")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await manager.refreshBackups()
            await manager.refreshCurrentMirror()
        }
    }

    // MARK: - Mirror

    @ViewBuilder
    private var mirrorSection: some View {
        Section {
            HStack {
                Text("当前镜像源")
                Spacer()
                Text(manager.currentMirrorName)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await manager.fixRepositoriesVersion() }
            } label: {
                HStack {
                    Label("修复仓库版本", systemImage: "wrench.and.screwdriver")
                    Spacer()
                    if manager.phase == .backingUp && manager.logLines.last?.contains("修复") == true {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(manager.phase.isBusy)
            .buttonStyle(.borderless)
            .listRowBackground(Color.clear)

            ForEach(RootfsManager.mirrorOptions.indices, id: \.self) { i in
                let mirror = RootfsManager.mirrorOptions[i]
                Button {
                    Task { await manager.switchMirror(to: mirror.url, name: mirror.name) }
                } label: {
                    HStack {
                        Text(mirror.name)
                        Spacer()
                        if manager.currentMirrorName == mirror.name {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .disabled(manager.phase.isBusy)
                .buttonStyle(.borderless)
                .listRowBackground(Color.clear)
            }
        } header: {
            Text("镜像源")
        } footer: {
            Text("如果 apk add 报「no such package」，点「修复仓库版本」可检测实际 Alpine 版本并重写 /etc/apk/repositories。")
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Update

    @ViewBuilder
    private var updateSection: some View {
        Section {
            Button {
                Task { await manager.checkUpdates() }
            } label: {
                rowLabel("检查更新", systemImage: "arrow.triangle.2.circlepath",
                         busy: manager.phase == .checkingUpdates)
            }
            .disabled(manager.phase.isBusy)
            .buttonStyle(.borderless)

            if !manager.upgradablePackages.isEmpty {
                Button {
                    Task { await manager.upgrade() }
                } label: {
                    rowLabel("升级 \(manager.upgradablePackages.count) 个包",
                             systemImage: "arrow.up.circle",
                             busy: manager.phase == .upgrading)
                }
                .disabled(manager.phase.isBusy)
                .buttonStyle(.borderless)

                ForEach(manager.upgradablePackages.indices, id: \.self) { i in
                    Text(manager.upgradablePackages[i])
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }

            if let statusText = phaseStatusText {
                HStack {
                    Text("状态")
                    Spacer()
                    Text(statusText)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        } header: {
            Text("软件包")
        } footer: {
            Text("通过 apk 从 Alpine 仓库检查并升级已安装的软件包。")
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Backup

    @ViewBuilder
    private var backupSection: some View {
        Section {
            Button {
                Task { await manager.backup() }
            } label: {
                rowLabel("备份用户数据", systemImage: "externaldrive.badge.plus",
                         busy: manager.phase == .backingUp)
            }
            .disabled(manager.phase.isBusy)
            .buttonStyle(.borderless)
        } header: {
            Text("备份")
        } footer: {
            Text("备份 /etc /root /home /var/lib 到 /root/velum-backups/。")
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Backups list

    @ViewBuilder
    private var backupsListSection: some View {
        if !manager.availableBackups.isEmpty {
            Section("已有备份") {
                ForEach(manager.availableBackups) { entry in
                    backupRow(entry)
                }
                .onDelete { idxSet in
                    Task {
                        for i in idxSet {
                            await manager.deleteBackup(manager.availableBackups[i])
                        }
                    }
                }
            }
            .listRowBackground(Color.clear)
        }
    }

    private func backupRow(_ entry: RootfsManager.BackupEntry) -> some View {
        let date = Date(timeIntervalSince1970: entry.mtime)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.filename)
                    .font(.callout.monospaced())
                Text("\(formatter.string(from: date)) · \(formattedSize(entry.sizeBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("恢复") {
                Task { await manager.restore(entry) }
            }
            .buttonStyle(.bordered)
            .disabled(manager.phase.isBusy)
        }
    }

    // MARK: - Log

    @ViewBuilder
    private var logSection: some View {
        if !manager.logLines.isEmpty {
            Section {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(manager.logLines.indices, id: \.self) { i in
                            Text(manager.logLines[i])
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 80, maxHeight: 200)

                Button("清除日志") {
                    manager.clearLog()
                }
                .disabled(manager.phase.isBusy)
                .buttonStyle(.borderless)
            } header: {
                Text("输出")
            }
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func rowLabel(_ title: String, systemImage: String, busy: Bool) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            if busy { ProgressView() }
        }
    }

    private var phaseStatusText: String? {
        switch manager.phase {
        case .idle: return nil
        case .checkingUpdates: return "正在检查…"
        case .upgrading: return "正在升级…"
        case .backingUp: return "正在备份…"
        case .restoring: return "正在恢复…"
        case .done(let msg): return msg
        case .failed(let msg): return "失败：\(msg)"
        }
    }

    private func formattedSize(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - About

/// 内容与独立 About App 共用 `AboutContentView`（见 WindowChrome.swift）。
private struct AboutView: View {
    var body: some View {
        AboutContentView()
            .navigationTitle("关于")
            .navigationBarTitleDisplayMode(.inline)
    }
}
