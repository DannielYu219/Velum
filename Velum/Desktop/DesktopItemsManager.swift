//
//  DesktopItemsManager.swift
//  Velum
//
//  桌面文件管理：在桌面上放置 / 拖拽 / 删除 fakefs 文件的引用。
//
//  说明：
//  - 桌面"图标"是 iSH fakefs 路径的引用 + 屏幕坐标；不会移动或复制原文件。
//  - 引用列表持久化到 Application Support/velum_desktop_items.json。
//  - "新建文件"会在 fakefs 的 /root/Desktop/ 目录下创建空文件并加入桌面。
//  - "删除"只移除桌面引用，不删除 fakefs 中的真实文件。
//

import Foundation
import SwiftUI

// MARK: - Model

struct DesktopItem: Identifiable, Codable, Hashable {
    let id: UUID
    var path: String          // iSH fakefs 绝对路径
    var position: CGPoint     // 桌面画布坐标系（左上角为原点）
    var createdAt: Date

    init(path: String, position: CGPoint) {
        self.id = UUID()
        self.path = path
        self.position = position
        self.createdAt = Date()
    }

    var name: String {
        (path as NSString).lastPathComponent
    }

    var ext: String {
        (path as NSString).pathExtension.lowercased()
    }
}

// MARK: - Manager

@MainActor
final class DesktopItemsManager: ObservableObject {

    static let shared = DesktopItemsManager()

    @Published private(set) var items: [DesktopItem] = []

    /// 当前选中的图标 id（用于视觉高亮）。
    @Published var selection: UUID?

    /// 桌面新建文件的存放目录（fakefs 内）。
    static let newFileDir = "/root/Desktop"

    private let storageURL: URL = {
        // 优先使用 Application Support；若不可用退回 Documents。
        // 两者都是 App sandbox 内的持久化位置，App 重启后仍然存在。
        let fm = FileManager.default
        let baseDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        return baseDir.appendingPathComponent("velum_desktop_items.json")
    }()

    private init() {
        load()
        #if DEBUG
        let url = storageURL.path
        let count = items.count
        print("[DesktopItems] init: loaded \(count) items from \(url)")
        #endif
    }

    // MARK: - CRUD

    /// 添加一个桌面引用；如果路径已存在则只更新位置。
    @discardableResult
    func add(path: String, position: CGPoint) -> DesktopItem {
        let clamped = Self.clampPosition(position, in: currentCanvas())
        if let idx = items.firstIndex(where: { $0.path == path }) {
            items[idx].position = clamped
            let updated = items[idx]
            save()
            return updated
        }
        let item = DesktopItem(path: path, position: clamped)
        items.append(item)
        save()
        return item
    }

    func updatePosition(id: UUID, position: CGPoint) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].position = Self.clampPosition(position, in: currentCanvas())
        save()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func remove(path: String) {
        items.removeAll { $0.path == path }
        save()
    }

    func removeAll() {
        items.removeAll()
        save()
    }

    /// 画布尺寸变化时，把所有图标夹回屏幕。
    func reclamp(in canvas: CGSize) {
        guard canvas.width > 1, canvas.height > 1 else { return }
        for i in items.indices {
            items[i].position = Self.clampPosition(items[i].position, in: canvas)
        }
        save()
    }

    /// 简单整理：按名称排序后以 6 列网格重新排布。
    func rearrange(in canvas: CGSize) {
        guard canvas.width > 1, canvas.height > 1 else { return }
        let sorted = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let cols = 6
        let startX: CGFloat = 24
        let startY: CGFloat = 36
        let stepX: CGFloat = Self.iconSize.width + 8
        let stepY: CGFloat = Self.iconSize.height + 8
        for (i, item) in sorted.enumerated() {
            let col = i % cols
            let row = i / cols
            let pos = CGPoint(x: startX + CGFloat(col) * stepX, y: startY + CGFloat(row) * stepY)
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx].position = Self.clampPosition(pos, in: canvas)
            }
        }
        save()
    }

    // MARK: - New file

    /// 在 fakefs /root/Desktop/ 下创建一个空文本文件，并将其加入桌面。
    /// 返回新创建的桌面项；失败时返回 nil。
    func createNewTextFile(at position: CGPoint) async -> DesktopItem? {
        let dir = Self.newFileDir
        let stamp = Self.stamp()
        var name = "untitled-\(stamp).txt"
        var fullPath = "\(dir)/\(name)"

        // 确保目录存在
        _ = try? await ISHBridge.shared.execute("mkdir -p \"\(dir)\"")

        // 同名时附加序号
        var n = 1
        while await ISHBridge.shared.exists(fullPath) {
            name = "untitled-\(stamp)-\(n).txt"
            fullPath = "\(dir)/\(name)"
            n += 1
            if n > 1000 { return nil }
        }

        // 写入空内容（touch 等价）
        _ = try? await ISHBridge.shared.writeTextFile(fullPath, text: "")

        return add(path: fullPath, position: position)
    }

    /// 在 fakefs /root/Desktop/ 下创建一个新目录，并加入桌面。
    func createNewFolder(at position: CGPoint) async -> DesktopItem? {
        let dir = Self.newFileDir
        let stamp = Self.stamp()
        var name = "NewFolder-\(stamp)"
        var fullPath = "\(dir)/\(name)"

        _ = try? await ISHBridge.shared.execute("mkdir -p \"\(dir)\"")

        var n = 1
        while await ISHBridge.shared.exists(fullPath) {
            name = "NewFolder-\(stamp)-\(n)"
            fullPath = "\(dir)/\(name)"
            n += 1
            if n > 1000 { return nil }
        }

        _ = try? await ISHBridge.shared.execute("mkdir -p \"\(fullPath)\"")

        return add(path: fullPath, position: position)
    }

    // MARK: - 持久化

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            #if DEBUG
            print("[DesktopItems] load: storage file does not exist yet")
            #endif
            return
        }
        do {
            let data = try Data(contentsOf: storageURL)
            let decoded = try JSONDecoder().decode([DesktopItem].self, from: data)
            self.items = decoded
            #if DEBUG
            print("[DesktopItems] load: decoded \(decoded.count) items")
            #endif
        } catch {
            #if DEBUG
            print("[DesktopItems] load FAILED: \(error)")
            #endif
            self.items = []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: storageURL, options: .atomic)
            #if DEBUG
            print("[DesktopItems] save: wrote \(items.count) items to \(storageURL.path)")
            #endif
        } catch {
            #if DEBUG
            print("[DesktopItems] save FAILED: \(error)")
            #endif
        }
    }

    // MARK: - Helpers

    private func currentCanvas() -> CGSize {
        WindowManager.shared.canvasSize
    }

    /// 桌面图标尺寸（用于位置夹取计算）。
    /// 整体放大约 50%：原 80×92 → 120×138。
    static let iconSize = CGSize(width: 120, height: 138)

    static func clampPosition(_ p: CGPoint, in canvas: CGSize) -> CGPoint {
        guard canvas.width > 1, canvas.height > 1 else { return p }
        let w = iconSize.width
        let h = iconSize.height
        // 顶部留出 TopBar 区域 16pt，底部留出 Dock 区域 100pt
        let maxX = max(w, canvas.width - w)
        let maxY = max(h + 16, canvas.height - 100)
        let x = min(max(0, p.x), maxX)
        let y = min(max(16, p.y), maxY)
        return CGPoint(x: x, y: y)
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
