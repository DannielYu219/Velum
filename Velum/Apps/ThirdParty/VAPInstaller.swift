//
//  VAPInstaller.swift
//  Velum
//
//  .vap（Velum App Package）安装器。
//
//  .vap 本质是一个 gzip 压缩的 tar 归档（与项目内 rootfs 备份使用的 tar czf/xzf
//  格式一致），根部包含一个 manifest.json（对应 ThirdPartyAppManifest），以及该
//  App 的资源文件（index.html / JS / ELF 等）。目录布局二选一：
//
//    package.vap
//    ├── manifest.json          # 资源在归档根部
//    ├── index.html
//    └── ...
//   或
//    package.vap
//    └── <任意单层目录>/
//        ├── manifest.json      # 资源包在一层目录内
//        └── ...
//
//  安装步骤：把 iOS 侧选中的 .vap 字节写进 iSH fakefs 暂存区 → 在 iSH 内 tar 解包
//  → 读取并解码 manifest.json → 落地到沙箱根 /var/lib/velum/apps/<id> → 交给
//  AppRegistry 注册。全程复用 ISHBridge，不引入新的解压依赖。
//
//  [安全加固 2026-08]
//  - prepare/land 两段式：UI 先 prepare（解包+读 manifest），用户确认权限后再 land。
//  - .vap 体积上限 256MB；解包后总大小上限 200MB（du -sk 校验）。
//  - tar 清单校验：拒绝绝对路径与 .. 分段（zip-slip）；拒绝指向沙箱外的 symlink。
//  - manifest 经 ThirdPartyAppManifest.installSafetyIssue 校验后才允许落地。
//

import Foundation
import UniformTypeIdentifiers
import os

// MARK: - UTType

public extension UTType {
    /// Velum App Package（.vap）。本质为 gzip 压缩的 tar 归档。
    /// 需与 Info.plist 的 UTImportedTypeDeclarations 中同名标识符对应。
    static var vapPackage: UTType {
        UTType(importedAs: "com.velum.app-package")
    }
}

// MARK: - Errors

public enum VAPInstallError: LocalizedError {
    case cannotReadFile(String)
    case fileTooLarge(String)
    case writeToGuestFailed(String)
    case unsafeArchive(String)
    case extractFailed(String)
    case manifestNotFound
    case manifestInvalid(String)
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cannotReadFile(let m):    return "无法读取 .vap 文件：\(m)"
        case .fileTooLarge(let m):      return "\(m)"
        case .writeToGuestFailed(let m): return "无法写入 Linux 文件系统：\(m)"
        case .unsafeArchive(let m):     return "归档不安全：\(m)"
        case .extractFailed(let m):     return "解包失败：\(m)"
        case .manifestNotFound:         return "包内未找到 manifest.json"
        case .manifestInvalid(let m):   return "manifest.json 无效：\(m)"
        case .installFailed(let m):     return "安装落地失败：\(m)"
        }
    }
}

// MARK: - Prepared package

/// 已解包、待用户确认后落地的包。land 只允许执行一次。
public struct PreparedVAP: @unchecked Sendable {
    public let manifest: ThirdPartyAppManifest
    fileprivate let staging: String
    fileprivate let vapPath: String
    fileprivate let payloadRoot: String
    private let landed = OSAllocatedUnfairLock(initialState: false)

    /// 落盘到 /var/lib/velum/apps/<id>（幂等：重复调用只执行一次）。
    public func land() async throws {
        let already = landed.withLock { v in
            let old = v
            v = true
            return old
        }
        if already { return }
        try await VAPInstaller.land(self)
    }

    /// 放弃安装：清理暂存区（之后 land 变为 no-op）。
    public func discard() async {
        let already = landed.withLock { v in
            let old = v
            v = true
            return old
        }
        if already { return }
        _ = try? await ISHBridge.shared.execute("rm -rf '\(staging)'")
    }
}

// MARK: - Installer

public enum VAPInstaller {

    /// App 沙箱父目录（每个 App 落地到 <parent>/<id>）。
    private static let appsParent = "/var/lib/velum/apps"

    /// .vap 文件体积上限。
    private static let maxPackageBytes = 256 * 1024 * 1024
    /// 解包后总大小上限（KB）。
    private static let maxExtractedKB = 200 * 1024

    /// 两段式第一步：读取 .vap → 写暂存 → 校验归档清单 → 解包 → 读并校验 manifest。
    /// 不落地沙箱；调用方展示权限并获得用户确认后，再调用 `land`。
    public static func prepare(from url: URL) async throws -> PreparedVAP {
        // 1) 读取 iOS 侧字节（security-scoped），带体积上限。
        let didScope = url.startAccessingSecurityScopedResource()
        defer { if didScope { url.stopAccessingSecurityScopedResource() } }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > maxPackageBytes {
            throw VAPInstallError.fileTooLarge(".vap 体积超过 256MB 上限")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw VAPInstallError.cannotReadFile(error.localizedDescription)
        }
        guard data.count <= maxPackageBytes else {
            throw VAPInstallError.fileTooLarge(".vap 体积超过 256MB 上限")
        }

        let bridge = ISHBridge.shared
        let token = UUID().uuidString
        let staging = "/tmp/velum-install/\(token)"
        let vapPath = "\(staging)/package.vap"
        let extractDir = "\(staging)/extract"

        // 2) 准备暂存区并把 .vap 写进 fakefs。
        _ = try? await bridge.execute("rm -rf '\(staging)'; mkdir -p '\(extractDir)'")
        do {
            _ = try await bridge.writeFile(vapPath, data: data)
        } catch {
            _ = try? await bridge.execute("rm -rf '\(staging)'")
            throw VAPInstallError.writeToGuestFailed(error.localizedDescription)
        }

        // 3) 归档清单校验（路径穿越 + symlink 逃逸）。
        try await validateArchive(vapPath: vapPath, bridge: bridge)

        // 4) 解包（优先 gzip tar，回退到自动识别的 tar）。
        let extractScript = """
        set -e
        cd '\(extractDir)'
        if tar xzf '\(vapPath)' 2>/dev/null; then true
        elif tar xf '\(vapPath)' 2>/dev/null; then true
        else echo 'unsupported or corrupt archive'; exit 3; fi
        """
        let ex = try await bridge.execute(extractScript)
        guard ex.isSuccess else {
            let msg = ex.output.isEmpty ? "exit \(ex.exitCode)" : ex.output
            _ = try? await bridge.execute("rm -rf '\(staging)'")
            throw VAPInstallError.extractFailed(msg)
        }

        // 5) 解压后大小校验（zip bomb 防护）。
        let du = try await bridge.execute("du -sk '\(extractDir)' 2>/dev/null | cut -f1")
        let extractedKB = Int(du.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Int.max
        guard extractedKB <= maxExtractedKB else {
            _ = try? await bridge.execute("rm -rf '\(staging)'")
            throw VAPInstallError.fileTooLarge("解包后体积超过 200MB 上限")
        }

        // 6) 定位包含 manifest.json 的目录（解包根或唯一单层子目录）。
        guard let payloadRoot = await locateManifestDir(extractDir, bridge: bridge) else {
            _ = try? await bridge.execute("rm -rf '\(staging)'")
            throw VAPInstallError.manifestNotFound
        }

        // 7) 读取并解码 manifest.json。
        let manifest: ThirdPartyAppManifest
        do {
            let text = try await bridge.readTextFile("\(payloadRoot)/manifest.json")
            guard let d = text.data(using: .utf8), !d.isEmpty else {
                throw VAPInstallError.manifestInvalid("文件为空")
            }
            manifest = try JSONDecoder().decode(ThirdPartyAppManifest.self, from: d)
        } catch let e as VAPInstallError {
            _ = try? await bridge.execute("rm -rf '\(staging)'")
            throw e
        } catch {
            _ = try? await bridge.execute("rm -rf '\(staging)'")
            throw VAPInstallError.manifestInvalid(error.localizedDescription)
        }

        // 8) manifest 安全校验（id 白名单 / entry / runtime）。
        if let issue = manifest.installSafetyIssue {
            _ = try? await bridge.execute("rm -rf '\(staging)'")
            throw VAPInstallError.manifestInvalid(issue)
        }

        return PreparedVAP(manifest: manifest, staging: staging,
                           vapPath: vapPath, payloadRoot: payloadRoot)
    }

    /// 两段式第二步：落地到沙箱根 /var/lib/velum/apps/<id>（覆盖旧版本）。
    static func land(_ p: PreparedVAP) async throws {
        let bridge = ISHBridge.shared
        let target = p.manifest.sandboxRoot
        let landScript = """
        set -e
        rm -rf '\(target)'
        mkdir -p '\(appsParent)'
        mv '\(p.payloadRoot)' '\(target)'
        """
        let landing = try await bridge.execute(landScript)
        _ = try? await bridge.execute("rm -rf '\(p.staging)'")
        guard landing.isSuccess else {
            let msg = landing.errorOutput.isEmpty ? (landing.output.isEmpty ? "exit \(landing.exitCode)" : landing.output) : landing.errorOutput
            throw VAPInstallError.installFailed(msg)
        }
    }

    /// 一步安装（兼容保留）：prepare + land。
    public static func install(from url: URL) async throws -> ThirdPartyAppManifest {
        let p = try await prepare(from: url)
        try await p.land()
        return p.manifest
    }

    // MARK: - Archive validation

    /// 校验 tar 归档：条目路径不得为绝对路径、不得含 .. 分段；symlink 目标不得越界。
    private static func validateArchive(vapPath: String, bridge: ISHBridge) async throws {
        // 条目清单（每行一条路径）
        let listing = try await bridge.execute("tar -tzf '\(vapPath)' 2>/dev/null")
        guard listing.isSuccess else {
            throw VAPInstallError.extractFailed("无法读取归档清单（exit \(listing.exitCode)）")
        }
        for raw in listing.output.split(separator: "\n") {
            var path = String(raw)
            if path.hasPrefix("./") { path.removeFirst(2) }
            guard !path.isEmpty else { continue }
            if path.hasPrefix("/") {
                throw VAPInstallError.unsafeArchive("包含绝对路径条目: \(path)")
            }
            if path.split(separator: "/").contains(where: { $0 == ".." }) {
                throw VAPInstallError.unsafeArchive("包含路径穿越条目: \(path)")
            }
        }
        // symlink 目标校验（tar -tv 对链接输出 "path -> target"）
        let verbose = try await bridge.execute("tar -tvzf '\(vapPath)' 2>/dev/null")
        guard verbose.isSuccess else {
            throw VAPInstallError.extractFailed("无法读取归档详情（exit \(verbose.exitCode)）")
        }
        for raw in verbose.output.split(separator: "\n") {
            let line = String(raw)
            guard let arrow = line.range(of: " -> ", options: .backwards) else { continue }
            let target = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { continue }
            if target.hasPrefix("/") || target.split(separator: "/").contains(where: { $0 == ".." }) {
                throw VAPInstallError.unsafeArchive("符号链接目标越界: \(target)")
            }
        }
    }

    /// 找到包含 manifest.json 的目录：优先解包根，其次唯一单层子目录。
    private static func locateManifestDir(_ root: String, bridge: ISHBridge) async -> String? {
        if await bridge.exists("\(root)/manifest.json") { return root }
        let entries = (try? await bridge.listDir(root)) ?? []
        let dirs = entries.filter { $0.isDirectory && $0.name != "." && $0.name != ".." }
        for d in dirs {
            let sub = "\(root)/\(d.name)"
            if await bridge.exists("\(sub)/manifest.json") { return sub }
        }
        return nil
    }
}
