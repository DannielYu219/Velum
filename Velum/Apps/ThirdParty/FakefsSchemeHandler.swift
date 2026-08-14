//
//  FakefsSchemeHandler.swift
//  Velum
//
//  自定义 URL scheme handler：把 velumapp://app/<相对路径> 的请求映射到 iSH fakefs
//  内的 <sandboxRoot>/<相对路径>，按需读取字节返回给 WKWebView。
//
//  背景：第三方 App 的 H5 资产存放在 iSH fakefs（如 /var/lib/velum/apps/<id>/），
//  这是内核内部的虚拟文件系统，**并不存在于 iOS 宿主磁盘**。因此不能用
//  FileManager / file:// URL 访问（那样永远找不到文件 → 一直显示"未就绪"）。
//  这里通过 ISHFsBridge（fakefs 的同步 Obj-C facade）按需读取，使 WKWebView 能
//  正确加载多文件 H5 包（HTML + 相对引用的 CSS/JS/图片）。
//
//  [安全加固 2026-08]
//  - 路径解析逐段展开符号链接并强制断言在 sandboxRoot 前缀内（防 symlink 逃逸）。
//  - 读取在后台串行队列执行，不再阻塞主线程。
//  - 支持单段 Range 请求（视频/音频拖动），全量读取设 64MB 上限。
//  - 目录请求回退 index.html；移除 ACAO:*，资产不再对其他源开放。
//

import Foundation
import WebKit

final class FakefsSchemeHandler: NSObject, WKURLSchemeHandler {

    /// 自定义 scheme（不可与 http/https/file 等保留 scheme 冲突）。
    nonisolated static let scheme = "velumapp"

    /// 该 App 在 fakefs 内的沙箱根目录。
    private let sandboxRoot: String

    /// 后台 IO 串行队列：fakefs 读取全部离开主线程。
    private static let ioQueue = DispatchQueue(label: "app.velum.schemehandler", qos: .userInitiated)

    /// 全量读取的内存上限（超过则 413 风格失败，媒体请走 Range）。
    private static let maxFullReadBytes = 64 * 1024 * 1024

    /// [性能] 小资源缓存：H5 页面 CSS/JS/图标等重复加载时零 fs 往返。
    /// [内存防护] 显式总量上限 8MB, 防止长会话下缓存无限累积。
    private static let cacheableMaxBytes = 256 * 1024
    private static let assetCache: NSCache<NSString, CachedAsset> = {
        let cache = NSCache<NSString, CachedAsset>()
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    final class CachedAsset: NSObject {
        let mtime: Int
        let size: UInt64
        let data: Data
        init(mtime: Int, size: UInt64, data: Data) {
            self.mtime = mtime
            self.size = size
            self.data = data
        }
    }

    init(sandboxRoot: String) {
        self.sandboxRoot = sandboxRoot
    }

    /// 构造页面入口 URL：velumapp://app/<entry>。
    static func entryURL(forEntry entry: String) -> URL {
        let clean = entry.hasPrefix("/") ? String(entry.dropFirst()) : entry
        return URL(string: "\(scheme)://app/\(clean)") ?? URL(string: "\(scheme)://app/index.html")!
    }

    // WKURLSchemeHandler 的回调在主线程触发；这里只摘取 URL/请求后立即转后台执行，
    // 完成后回主线程投递响应。
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let request = urlSchemeTask.request
        Self.ioQueue.async {
            self.serve(url: url, request: request, task: urlSchemeTask)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // 读取是短时同步操作，无可取消的挂起任务。
    }

    // MARK: - Serving

    private func serve(url: URL, request: URLRequest, task: WKURLSchemeTask) {
        let fs = ISHFsBridge.sharedInstance()

        guard var path = Self.sandboxedPath(url: url, sandboxRoot: sandboxRoot, fs: fs) else {
            Self.fail(task, URLError(.fileDoesNotExist))
            return
        }

        // 目录请求 → 回退 index.html
        if let st = try? fs.statPath(path), !Self.isRegularFile(st.mode) {
            let idx = path.hasSuffix("/") ? path + "index.html" : path + "/index.html"
            guard fs.exists(idx) else {
                Self.fail(task, URLError(.fileDoesNotExist))
                return
            }
            path = idx
        }

        guard let st = try? fs.statPath(path), Self.isRegularFile(st.mode) else {
            Self.fail(task, URLError(.fileDoesNotExist))
            return
        }
        let total = Int(st.size)

        // 小资源缓存命中（mtime/size 一致）→ 零 fs 调用直接返回。
        if total > 0, total <= Self.cacheableMaxBytes,
           let cached = Self.assetCache.object(forKey: path as NSString),
           cached.mtime == st.mtime, cached.size == st.size {
            let headers = [
                "Content-Type": Self.mimeType(forPath: path),
                "Content-Length": "\(cached.data.count)",
                "Accept-Ranges": "bytes",
                "Cache-Control": "no-cache"
            ]
            let resp = HTTPURLResponse(url: url, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
            Self.deliver(task, resp, cached.data)
            return
        }

        if total > 0, let range = Self.parseRange(request.value(forHTTPHeaderField: "Range"), total: total) {
            // 单段 Range 响应（206）
            do {
                let piece = try readRange(path: path, fs: fs, range: range)
                var headers = [
                    "Content-Type": Self.mimeType(forPath: path),
                    "Content-Length": "\(piece.count)",
                    "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound)/\(total)",
                    "Accept-Ranges": "bytes",
                    "Cache-Control": "no-cache"
                ]
                _ = headers
                let resp = HTTPURLResponse(url: url, statusCode: 206,
                                           httpVersion: "HTTP/1.1", headerFields: headers)!
                Self.deliver(task, resp, piece)
            } catch {
                Self.fail(task, URLError(.cannotDecodeContentData))
            }
            return
        }

        // 全量响应（200）
        guard total <= Self.maxFullReadBytes else {
            Self.fail(task, URLError(.resourceUnavailable))
            return
        }
        do {
            let data = try readAll(path: path, fs: fs, total: total)
            // 小资源写入缓存(下次同 mtime/size 直接命中), 以字节数为 cost 参与总量上限。
            if total <= Self.cacheableMaxBytes {
                Self.assetCache.setObject(CachedAsset(mtime: st.mtime, size: st.size, data: data),
                                          forKey: path as NSString, cost: total)
            }
            let headers = [
                "Content-Type": Self.mimeType(forPath: path),
                "Content-Length": "\(data.count)",
                "Accept-Ranges": "bytes",
                "Cache-Control": "no-cache"
            ]
            let resp = HTTPURLResponse(url: url, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
            Self.deliver(task, resp, data)
        } catch {
            Self.fail(task, URLError(.cannotDecodeContentData))
        }
    }

    private func readRange(path: String, fs: ISHFsBridge, range: ClosedRange<Int>) throws -> Data {
        // ISHFsBridge.readFile 单次最多 1MB, 必须循环读取才能服务完整 Range。
        let length = range.upperBound - range.lowerBound + 1
        var data = Data(capacity: length)
        var offset = range.lowerBound
        while data.count < length {
            let want = min(length - data.count, 1 << 20)
            guard let piece = try? fs.readFile(path, offset: off_t(offset), length: size_t(want)),
                  !piece.isEmpty else {
                break
            }
            data.append(piece)
            offset += piece.count
        }
        guard !data.isEmpty else {
            throw NSError(domain: "velum.scheme", code: 1)
        }
        return data
    }

    /// 分块读取整个文件。
    private func readAll(path: String, fs: ISHFsBridge, total: Int) throws -> Data {
        guard total > 0 else { return Data() }
        var data = Data(capacity: total)
        var offset: off_t = 0
        let chunk = 1 << 20   // 1MB
        while data.count < total {
            let remaining = total - data.count
            let want = min(remaining, chunk)
            let piece = try fs.readFile(path, offset: offset, length: size_t(want))
            if piece.isEmpty { break }
            data.append(piece)
            offset += off_t(piece.count)
        }
        return data
    }

    // MARK: - Path resolution（与 VelumJSBridge 共用同一套沙箱语义）

    /// 把请求 URL 解析为 sandboxRoot 内的 fakefs 绝对路径；越界返回 nil。
    static func sandboxedPath(url: URL, sandboxRoot: String, fs: ISHFsBridge) -> String? {
        var rel = url.path
        if rel.hasPrefix("/") { rel.removeFirst() }
        // 过滤掉 .. 分段，避免逃出沙箱根。
        let safe = rel.split(separator: "/").filter { $0 != ".." && $0 != "." }.joined(separator: "/")
        let joined = safe.isEmpty ? sandboxRoot : "\(sandboxRoot)/\(safe)"
        guard let resolved = resolveSymlinks(path: joined, fs: fs, depth: 0) else { return nil }
        guard resolved == sandboxRoot || resolved.hasPrefix(sandboxRoot + "/") else { return nil }
        return resolved
    }

    /// 字符串路径版本（VelumJSBridge 的文件读写使用）。
    static func sandboxedPath(_ raw: String, sandboxRoot: String, fs: ISHFsBridge) -> String? {
        let candidate = raw.hasPrefix("/") ? raw : "\(sandboxRoot)/\(raw)"
        guard let resolved = resolveSymlinks(path: candidate, fs: fs, depth: 0) else { return nil }
        guard resolved == sandboxRoot || resolved.hasPrefix(sandboxRoot + "/") else { return nil }
        return resolved
    }

    /// 逐段解析符号链接（最多 16 层），返回规范化绝对路径；无法解析返回 nil。
    /// 不存在的段按原样保留（写入新文件的场景：父目录已解析即可）。
    static func resolveSymlinks(path: String, fs: ISHFsBridge, depth: Int) -> String? {
        guard depth < 16, path.hasPrefix("/") else { return nil }
        var resolved = ""
        for comp in path.split(separator: "/") {
            let candidate = resolved.isEmpty ? "/\(comp)" : "\(resolved)/\(comp)"
            if !fs.exists(candidate) {
                resolved = candidate
                continue
            }
            if let target = try? fs.readlinkPath(candidate), !target.isEmpty {
                let next = target.hasPrefix("/") ? target : "\(resolved.isEmpty ? "" : resolved)/\(target)"
                guard let r = resolveSymlinks(path: next, fs: fs, depth: depth + 1) else { return nil }
                resolved = r
            } else {
                resolved = candidate
            }
        }
        return resolved
    }

    // MARK: - Helpers

    static func isRegularFile(_ mode: UInt16) -> Bool {
        (mode & 0o170000) == 0o100000   // S_IFREG
    }

    /// 解析单段 Range 头，如 "bytes=0-1023" / "bytes=512-"。
    private static func parseRange(_ header: String?, total: Int) -> ClosedRange<Int>? {
        guard let header, header.hasPrefix("bytes="), total > 0 else { return nil }
        let spec = header.dropFirst("bytes=".count)
        guard let dash = spec.firstIndex(of: "-") else { return nil }
        let startStr = spec[..<dash].trimmingCharacters(in: .whitespaces)
        let endStr = spec[spec.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        let start = startStr.isEmpty ? 0 : (Int(startStr) ?? -1)
        let end = endStr.isEmpty ? total - 1 : (Int(endStr) ?? -1)
        guard start >= 0, start < total, end >= start else { return nil }
        return start...min(end, total - 1)
    }

    private static func deliver(_ task: WKURLSchemeTask, _ resp: URLResponse, _ data: Data) {
        DispatchQueue.main.async {
            task.didReceive(resp)
            task.didReceive(data)
            task.didFinish()
        }
    }

    private static func fail(_ task: WKURLSchemeTask, _ error: URLError) {
        DispatchQueue.main.async {
            task.didFailWithError(error)
        }
    }

    /// 依扩展名给出 Content-Type。
    private static func mimeType(forPath path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs":   return "text/javascript; charset=utf-8"
        case "css":         return "text/css; charset=utf-8"
        case "json":        return "application/json; charset=utf-8"
        case "svg":         return "image/svg+xml"
        case "png":         return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        case "ico":         return "image/x-icon"
        case "wasm":        return "application/wasm"
        case "woff":        return "font/woff"
        case "woff2":       return "font/woff2"
        case "ttf":         return "font/ttf"
        case "otf":         return "font/otf"
        case "txt":         return "text/plain; charset=utf-8"
        default:            return "application/octet-stream"
        }
    }
}
