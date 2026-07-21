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

import Foundation
import WebKit

final class FakefsSchemeHandler: NSObject, WKURLSchemeHandler {

    /// 自定义 scheme（不可与 http/https/file 等保留 scheme 冲突）。
    static let scheme = "velumapp"

    /// 构造页面入口 URL：velumapp://app/<entry>。
    static func entryURL(forEntry entry: String) -> URL {
        let clean = entry.hasPrefix("/") ? String(entry.dropFirst()) : entry
        return URL(string: "\(scheme)://app/\(clean)") ?? URL(string: "\(scheme)://app/index.html")!
    }

    /// 该 App 在 fakefs 内的沙箱根目录。
    private let sandboxRoot: String

    init(sandboxRoot: String) {
        self.sandboxRoot = sandboxRoot
    }

    // WKURLSchemeHandler 的回调在主线程触发；fakefs 读取为同步小 IO，直接完成。
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        let fakePath = resolve(url)
        let fs = ISHFsBridge.sharedInstance()

        guard fs.exists(fakePath) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        do {
            let data = try readAll(path: fakePath, fs: fs)
            let headers = [
                "Content-Type": Self.mimeType(forPath: fakePath),
                "Content-Length": "\(data.count)",
                "Access-Control-Allow-Origin": "*",
                "Cache-Control": "no-cache"
            ]
            let resp = HTTPURLResponse(url: url, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
            urlSchemeTask.didReceive(resp)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // 同步完成，无挂起任务需要取消。
    }

    // MARK: - Helpers

    /// 把请求 URL 的路径解析为 fakefs 绝对路径（拒绝 .. 逃逸）。
    private func resolve(_ url: URL) -> String {
        var rel = url.path
        if rel.hasPrefix("/") { rel.removeFirst() }
        // 过滤掉 .. 分段，避免逃出沙箱根。
        let safe = rel.split(separator: "/").filter { $0 != ".." && $0 != "." }.joined(separator: "/")
        return safe.isEmpty ? sandboxRoot : "\(sandboxRoot)/\(safe)"
    }

    /// 分块读取整个文件（应对大文件 / 单次 read 的部分返回）。
    private func readAll(path: String, fs: ISHFsBridge) throws -> Data {
        let stat = try fs.statPath(path)
        let total = Int(stat.size)
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
