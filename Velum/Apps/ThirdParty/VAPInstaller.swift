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

import Foundation
import UniformTypeIdentifiers

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
    case writeToGuestFailed(String)
    case extractFailed(String)
    case manifestNotFound
    case manifestInvalid(String)
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cannotReadFile(let m):    return "无法读取 .vap 文件：\(m)"
        case .writeToGuestFailed(let m): return "无法写入 Linux 文件系统：\(m)"
        case .extractFailed(let m):     return "解包失败：\(m)"
        case .manifestNotFound:         return "包内未找到 manifest.json"
        case .manifestInvalid(let m):   return "manifest.json 无效：\(m)"
        case .installFailed(let m):     return "安装落地失败：\(m)"
        }
    }
}

// MARK: - Installer

public enum VAPInstaller {

    /// App 沙箱父目录（每个 App 落地到 <parent>/<id>）。
    private static let appsParent = "/var/lib/velum/apps"

    /// 安装一个 .vap 包，返回解析出的 manifest（尚未注册，调用方负责注册）。
    public static func install(from url: URL) async throws -> ThirdPartyAppManifest {
        // 1) 读取 iOS 侧字节（security-scoped）。
        let didScope = url.startAccessingSecurityScopedResource()
        defer { if didScope { url.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw VAPInstallError.cannotReadFile(error.localizedDescription)
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

        // 3) 解包（优先 gzip tar，回退到自动识别的 tar）。
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

        // 4) 定位包含 manifest.json 的目录（解包根或唯一单层子目录）。
        guard let payloadRoot = await locateManifestDir(extractDir, bridge: bridge) else {
            _ = try? await bridge.execute("rm -rf '\(staging)'")
            throw VAPInstallError.manifestNotFound
        }

        // 5) 读取并解码 manifest.json。
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

        // 6) 落地到沙箱根：/var/lib/velum/apps/<id>（覆盖旧版本）。
        let target = manifest.sandboxRoot
        let landScript = """
        set -e
        rm -rf '\(target)'
        mkdir -p '\(appsParent)'
        mv '\(payloadRoot)' '\(target)'
        """
        let landing = try await bridge.execute(landScript)
        _ = try? await bridge.execute("rm -rf '\(staging)'")
        guard landing.isSuccess else {
            let msg = landing.errorOutput.isEmpty ? (landing.output.isEmpty ? "exit \(landing.exitCode)" : landing.output) : landing.errorOutput
            throw VAPInstallError.installFailed(msg)
        }

        return manifest
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
