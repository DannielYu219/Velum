//
//  WallpaperManager.swift
//  Velum
//
//  桌面壁纸管理 — 支持从照片或文件选取自定义壁纸。
//  图片持久化到 App Documents 目录。
//

import SwiftUI

@MainActor
public final class WallpaperManager: ObservableObject {
    public static let shared = WallpaperManager()

    @Published public private(set) var customImage: UIImage? = nil

    private let fileName = "velum_wallpaper.dat"

    private init() {
        customImage = loadFromDisk()
    }

    public func setImage(_ image: UIImage) {
        customImage = image
        saveToDisk(image)
    }

    public func clearImage() {
        customImage = nil
        deleteFromDisk()
    }

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent(fileName)
    }

    private func saveToDisk(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        try? data.write(to: fileURL)
    }

    private func loadFromDisk() -> UIImage? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return UIImage(data: data)
    }

    private func deleteFromDisk() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
