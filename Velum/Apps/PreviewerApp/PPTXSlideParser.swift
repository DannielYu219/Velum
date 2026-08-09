//
//  PPTXSlideParser.swift
//  Velum
//
//  纯 Swift 最小 ZIP 读取器 + pptx 幻灯片标题提取。
//
//  背景：用户要求在 PPT 显示区右侧内联一个缩略图/页导航，而不是弹
//  系统全屏预览。iOS 没有逐页渲染 pptx 的公开 API，但 pptx 本质是
//  zip：解析 ppt/slides/slideN.xml 拿到页数与每页标题，即可构建右侧
//  导航列表；点击时驱动 QuickLook 内部 UIScrollView 滚动到对应页。
//
//  仅依赖系统 Compression（zlib/deflate 解压），无第三方库。
//

import Foundation
import Compression

struct PPTXSlide: Identifiable, Sendable, Equatable {
    /// 0-based 页序
    let index: Int
    /// 该页第一个文本 run（标题），无则 "第 N 页"
    let title: String
    var id: Int { index }
}

enum PPTXSlideParser {

    /// 后台解析；失败返回空数组（导航不显示，不影响主预览）。
    static func parse(url: URL) async -> [PPTXSlide] {
        await Task.detached(priority: .userInitiated) {
            parseSync(url: url)
        }.value
    }

    // MARK: - 同步解析

    static func parseSync(url: URL) -> [PPTXSlide] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let entries = centralDirectory(data) else { return [] }

        // 取 ppt/slides/slideN.xml，按 N 排序
        let slideEntries: [(n: Int, entry: ZipEntry)] = entries.compactMap { e in
            guard let m = e.name.range(of: #"^ppt/slides/slide(\d+)\.xml$"#, options: .regularExpression) else {
                return nil
            }
            let numPart = e.name[m].replacingOccurrences(of: #"^\D+|\D+$"#, with: "", options: .regularExpression)
            guard let n = Int(numPart) else { return nil }
            return (n, e)
        }
        .sorted { $0.n < $1.n }

        guard !slideEntries.isEmpty else { return [] }

        var slides: [PPTXSlide] = []
        for (i, item) in slideEntries.enumerated() {
            let title = extractTitle(data: data, entry: item.entry)
                ?? "第 \(i + 1) 页"
            slides.append(PPTXSlide(index: i, title: title))
        }
        return slides
    }

    /// 解压单个 entry 并提取第一个 <a:t>…</a:t> 文本。
    private static func extractTitle(data: Data, entry: ZipEntry) -> String? {
        guard let xml = decompress(data: data, entry: entry),
              let text = String(data: xml, encoding: .utf8) else { return nil }
        guard let openRange = text.range(of: "<a:t>") ?? text.range(of: "<a:t ") else { return nil }
        let searchStart: String.Index
        if let closeTag = text.range(of: ">", range: openRange.upperBound..<text.endIndex) {
            searchStart = closeTag.upperBound
        } else {
            return nil
        }
        guard let endRange = text.range(of: "</a:t>", range: searchStart..<text.endIndex) else { return nil }
        let raw = String(text[searchStart..<endRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        // 截断过长标题
        return raw.count > 24 ? String(raw.prefix(24)) + "…" : raw
    }

    // MARK: - ZIP 结构

    private struct ZipEntry {
        let name: String
        let method: UInt16     // 0=store, 8=deflate
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    /// 扫描 EOCD + Central Directory。
    private static func centralDirectory(_ d: Data) -> [ZipEntry]? {
        guard d.count > 22 else { return nil }
        // 从尾部向前找 EOCD 签名 0x06054b50
        var eocd = -1
        var i = d.count - 22
        while i >= 0 {
            if u32(d, i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return nil }

        let entryCount = Int(u16(d, eocd + 10))
        var offset = Int(u32(d, eocd + 16))

        var entries: [ZipEntry] = []
        for _ in 0..<entryCount {
            guard offset + 46 <= d.count, u32(d, offset) == 0x02014b50 else { return entries }
            let method = u16(d, offset + 10)
            let compSize = Int(u32(d, offset + 20))
            let uncompSize = Int(u32(d, offset + 24))
            let nameLen = Int(u16(d, offset + 28))
            let extraLen = Int(u16(d, offset + 30))
            let commentLen = Int(u16(d, offset + 32))
            let localOffset = Int(u32(d, offset + 42))
            let name = String(data: d.subdata(in: (offset + 46)..<(offset + 46 + nameLen)), encoding: .utf8) ?? ""
            entries.append(ZipEntry(name: name, method: method,
                                    compressedSize: compSize, uncompressedSize: uncompSize,
                                    localHeaderOffset: localOffset))
            offset += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    /// 按 local header 定位压缩数据并解压。
    private static func decompress(data d: Data, entry: ZipEntry) -> Data? {
        let lh = entry.localHeaderOffset
        guard lh + 30 <= d.count, u32(d, lh) == 0x04034b50 else { return nil }
        let nameLen = Int(u16(d, lh + 26))
        let extraLen = Int(u16(d, lh + 28))
        let dataStart = lh + 30 + nameLen + extraLen
        let dataEnd = dataStart + entry.compressedSize
        guard dataEnd <= d.count else { return nil }
        let compressed = d.subdata(in: dataStart..<dataEnd)

        if entry.method == 0 {
            return compressed
        }
        guard entry.method == 8, entry.uncompressedSize > 0 else { return nil }

        var out = Data(count: entry.uncompressedSize)
        let written = out.withUnsafeMutableBytes { dst in
            compressed.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
                    src.bindMemory(to: UInt8.self).baseAddress!, src.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == entry.uncompressedSize else { return nil }
        return out
    }

    // MARK: - 小端读取

    private static func u16(_ d: Data, _ o: Int) -> UInt16 {
        UInt16(littleEndian: d.subdata(in: o..<(o + 2)).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })
    }

    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(littleEndian: d.subdata(in: o..<(o + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
    }
}
