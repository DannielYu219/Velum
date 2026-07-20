//
//  PreviewerViewModel.swift
//  Velum
//
//  Universal previewer ViewModel.
//  Loads content from an iSH fakefs path, a remote URL, or a local file URL,
//  detects the preview type by extension, and prepares data / temp file URLs
//  for the renderer views.
//
//  Data source: ISHBridge.shared (fakefs) + URLSession (remote).
//

import Foundation

@MainActor
final class PreviewerViewModel: ObservableObject {

    // MARK: - Types

    enum PreviewType {
        case pdf
        case html
        case markdown
        case image
        case video
        case audio
        case office     // pptx / docx / doc / ppt / xlsx / xls / rtf → QuickLook
        case text       // txt / log / conf / csv / json / xml / unknown text
    }

    struct PreviewContent {
        let type: PreviewType
        /// Raw bytes for data-backed renderers (PDF / image / markdown / html / text).
        let data: Data?
        /// On-disk URL for renderers that require a file (video / audio / office).
        let fileURL: URL?
        /// Remote URL for streamable renderers (html / video / audio).
        let remoteURL: URL?
        let title: String
    }

    enum PreviewState: Equatable {
        case empty
        case loading(String)
        case loaded(PreviewContent)
        case failed(String)

        static func == (lhs: PreviewState, rhs: PreviewState) -> Bool {
            switch (lhs, rhs) {
            case (.empty, .empty): return true
            case (.loading(let a), .loading(let b)): return a == b
            case (.failed(let a), .failed(let b)): return a == b
            case (.loaded, .loaded): return true
            default: return false
            }
        }
    }

    // MARK: - Published state

    @Published var addressText: String = ""
    @Published var previewState: PreviewState = .empty

    @Published var showSidebar: Bool = true
    @Published var sidebarPath: String = "/"
    @Published var sidebarEntries: [ISHDirEntry] = []
    @Published var isLoadingSidebar: Bool = false
    @Published var sidebarError: String?

    // MARK: - Private

    private let bridge = ISHBridge.shared

    // MARK: - Preview loading

    func loadPreview() async {
        let address = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }

        if address.hasPrefix("http://") || address.hasPrefix("https://") {
            guard let url = URL(string: address) else {
                previewState = .failed("无效的 URL")
                return
            }
            await loadRemote(url: url)
        } else if address.hasPrefix("file://") {
            if let url = URL(string: address) {
                loadLocalFile(url: url)
            }
        } else {
            await loadFakefsPath(address)
        }
    }

    func loadFromPath(_ path: String) async {
        addressText = path
        await loadFakefsPath(path)
    }

    // MARK: Remote

    private func loadRemote(url: URL) async {
        let ext = url.pathExtension
        let type = PreviewerViewModel.typeFor(ext: ext)
        let title = url.lastPathComponent

        switch type {
        case .html:
            previewState = .loaded(PreviewContent(
                type: .html, data: nil, fileURL: nil, remoteURL: url, title: title))
        case .video:
            previewState = .loaded(PreviewContent(
                type: .video, data: nil, fileURL: nil, remoteURL: url, title: title))
        case .audio:
            previewState = .loaded(PreviewContent(
                type: .audio, data: nil, fileURL: nil, remoteURL: url, title: title))
        default:
            previewState = .loading("下载中…")
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                try await applyData(data: data, ext: ext, title: title, remoteURL: url)
            } catch {
                previewState = .failed("下载失败: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Local iOS file

    private func loadLocalFile(url: URL) {
        let ext = url.pathExtension
        let type = PreviewerViewModel.typeFor(ext: ext)
        if let data = try? Data(contentsOf: url) {
            Task { try? await applyData(data: data, ext: ext, title: url.lastPathComponent, remoteURL: nil) }
        } else {
            previewState = .loaded(PreviewContent(
                type: type, data: nil, fileURL: url, remoteURL: nil, title: url.lastPathComponent))
        }
    }

    // MARK: iSH fakefs

    private func loadFakefsPath(_ path: String) async {
        previewState = .loading("读取 \(path)…")
        do {
            let data = try await bridge.readFile(path)
            let ext = (path as NSString).pathExtension
            let title = (path as NSString).lastPathComponent
            try await applyData(data: data, ext: ext, title: title, remoteURL: nil)
        } catch {
            previewState = .failed(error.localizedDescription)
        }
    }

    /// Persist data-backed content as a temp file when the renderer needs a URL,
    /// then publish the loaded state.
    private func applyData(data: Data, ext: String, title: String, remoteURL: URL?) async throws {
        let type = PreviewerViewModel.typeFor(ext: ext)
        var fileURL: URL?

        switch type {
        case .video, .audio, .office:
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext.isEmpty ? "bin" : ext)
            try data.write(to: url, options: .atomic)
            fileURL = url
        default:
            break
        }

        previewState = .loaded(PreviewContent(
            type: type,
            data: data,
            fileURL: fileURL,
            remoteURL: remoteURL,
            title: title))
    }

    // MARK: - Sidebar (file directory index, reuses Files App data source)

    func loadSidebar() async {
        isLoadingSidebar = true
        sidebarError = nil
        do {
            sidebarEntries = try await bridge.listDir(sidebarPath)
        } catch {
            sidebarError = error.localizedDescription
            sidebarEntries = []
        }
        isLoadingSidebar = false
    }

    func navigateInto(_ name: String) {
        sidebarPath = sidebarPath == "/" ? "/\(name)" : "\(sidebarPath)/\(name)"
        Task { await loadSidebar() }
    }

    func navigateUp() {
        guard sidebarPath != "/" else { return }
        let components = sidebarPath.split(separator: "/")
        if components.isEmpty {
            sidebarPath = "/"
        } else {
            sidebarPath = "/" + components.dropLast().joined(separator: "/")
        }
        Task { await loadSidebar() }
    }

    /// Select a sidebar file entry for preview.
    func selectFile(_ entry: ISHDirEntry) async {
        let full = sidebarPath == "/" ? "/\(entry.name)" : "\(sidebarPath)/\(entry.name)"
        await loadFromPath(full)
    }

    var sortedSidebarEntries: [ISHDirEntry] {
        sidebarEntries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: - Type detection

    static func typeFor(ext: String) -> PreviewType {
        switch ext.lowercased() {
        case "pdf":
            return .pdf
        case "html", "htm":
            return .html
        case "md", "markdown":
            return .markdown
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif",
             "bmp", "tiff", "tif", "ico":
            return .image
        case "mp4", "mov", "m4v", "avi", "webm", "3gp":
            return .video
        case "mp3", "wav", "m4a", "aac", "flac", "ogg", "opus", "caf":
            return .audio
        case "pptx", "ppt", "docx", "doc", "xlsx", "xls", "rtf":
            return .office
        default:
            return .text
        }
    }
}
