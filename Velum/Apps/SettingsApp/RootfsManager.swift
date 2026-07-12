//
//  RootfsManager.swift
//  Velum
//
//  Phase 7.2: rootfs 管理 — 检查更新 / 备份 / 恢复 / apk upgrade
//  通过 ISHBridge 调用 iSH 内的 apk 和 tar 命令。
//

import Foundation
import SwiftUI

@MainActor
final class RootfsManager: ObservableObject {

    // MARK: - Published state

    @Published var phase: Phase = .idle
    @Published var logLines: [String] = []
    @Published var upgradablePackages: [String] = []
    @Published var availableBackups: [BackupEntry] = []
    @Published var currentMirrorName: String = "未知"

    // MARK: - Types

    enum Phase: Equatable {
        case idle
        case checkingUpdates
        case upgrading
        case backingUp
        case restoring
        case done(String)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .checkingUpdates, .upgrading, .backingUp, .restoring: return true
            default: return false
            }
        }
    }

    struct BackupEntry: Identifiable, Hashable {
        let filename: String
        let sizeBytes: UInt64
        let mtime: TimeInterval
        var id: String { filename }
    }

    // MARK: - Constants

    private let backupDir = "/root/velum-backups"

    // MARK: - Update

    /// `apk update` 刷新仓库索引，然后列出可升级包。
    func checkUpdates() async {
        phase = .checkingUpdates
        appendLog("▸ apk update")
        do {
            let r = try await ISHBridge.shared.execute("apk update 2>&1")
            appendLog(r.output)
            guard r.isSuccess else {
                phase = .failed("apk update 失败 (exit \(r.exitCode))")
                return
            }
            appendLog("▸ apk list --upgradable")
            let list = try await ISHBridge.shared.execute("apk list --upgradable 2>&1")
            appendLog(list.output)
            upgradablePackages = parseUpgradable(list.output)
            if upgradablePackages.isEmpty {
                phase = .done("已是最新")
            } else {
                phase = .done("\(upgradablePackages.count) 个可升级包")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// `apk upgrade` 升级所有已安装包。
    func upgrade() async {
        phase = .upgrading
        appendLog("▸ apk upgrade")
        do {
            let r = try await ISHBridge.shared.execute("apk upgrade 2>&1")
            appendLog(r.output)
            if r.isSuccess {
                upgradablePackages = []
                phase = .done("升级完成")
            } else {
                phase = .failed("apk upgrade 失败 (exit \(r.exitCode))")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Backup / Restore

    /// 备份用户数据（/etc /root /home /var/lib）到 tar.gz。
    func backup() async {
        phase = .backingUp
        let stamp = Self.stampFormatter.string(from: Date())
        let path = "\(backupDir)/rootfs-\(stamp).tar.gz"

        appendLog("▸ mkdir -p \(backupDir)")
        _ = try? await ISHBridge.shared.execute("mkdir -p \(backupDir)")

        appendLog("▸ tar czf \(path) -C / etc root home var/lib 2>&1")
        do {
            let r = try await ISHBridge.shared.execute(
                "tar czf \(path) -C / etc root home var/lib 2>&1"
            )
            appendLog(r.output)
            if r.isSuccess {
                appendLog("备份完成：\(path)")
                phase = .done("备份完成")
                await refreshBackups()
            } else {
                phase = .failed("备份失败 (exit \(r.exitCode))")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// 从备份恢复。
    func restore(_ entry: BackupEntry) async {
        let path = "\(backupDir)/\(entry.filename)"
        phase = .restoring
        appendLog("▸ tar xzf \(path) -C / 2>&1")
        do {
            let r = try await ISHBridge.shared.execute("tar xzf \(path) -C / 2>&1")
            appendLog(r.output)
            if r.isSuccess {
                phase = .done("恢复完成")
            } else {
                phase = .failed("恢复失败 (exit \(r.exitCode))")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// 列出已有备份。
    func refreshBackups() async {
        do {
            let entries = try await ISHBridge.shared.listDir(backupDir)
            availableBackups = entries
                .filter { $0.name.hasSuffix(".tar.gz") }
                .map { BackupEntry(filename: $0.name, sizeBytes: $0.size, mtime: $0.mtime) }
                .sorted { $0.mtime > $1.mtime }
        } catch {
            availableBackups = []
        }
    }

    /// 删除指定备份。
    func deleteBackup(_ entry: BackupEntry) async {
        let path = "\(backupDir)/\(entry.filename)"
        appendLog("▸ rm -f \(path)")
        _ = try? await ISHBridge.shared.execute("rm -f \(path)")
        await refreshBackups()
    }

    // MARK: - Mirror management

    /// 可选的镜像源列表
    static let mirrorOptions: [(name: String, url: String)] = [
        ("清华大学 TUNA", "https://mirrors.tuna.tsinghua.edu.cn/alpine"),
        ("中科大 USTC",   "https://mirrors.ustc.edu.cn/alpine"),
        ("阿里云",        "https://mirrors.aliyun.com/alpine"),
        ("官方源",        "https://dl-cdn.alpinelinux.org/alpine"),
    ]

    /// 修复 apk 仓库版本：从 /etc/os-release 读取实际版本，重写 /etc/apk/repositories
    func fixRepositoriesVersion() async {
        phase = .backingUp
        appendLog("▸ 检测并修复 apk 仓库版本")
        do {
            let script = """
            set -e
            v=$(grep -oE 'VERSION_ID=v?[0-9]+\\.[0-9]+' /etc/os-release 2>/dev/null | grep -oE 'v[0-9]+\\.[0-9]+' | head -1)
            if [ -z \"$v\" ]; then
              v=$(cat /etc/apk/repositories 2>/dev/null | grep -oE 'v[0-9]+\\.[0-9]+' | head -1)
            fi
            if [ -z \"$v\" ]; then
              v='v3.21'
            fi
            echo \"检测到 Alpine $v\"
            current=$(cat /etc/apk/repositories 2>/dev/null | grep -oE 'v[0-9]+\\.[0-9]+' | head -1)
            echo \"当前仓库版本: ${current:-无}\"
            if [ \"$v\" != \"$current\" ]; then
              mirror=$(cat /etc/apk/repositories 2>/dev/null | grep -oE 'https?://[^/]+/alpine' | head -1)
              if [ -z \"$mirror\" ]; then
                mirror='https://mirrors.tuna.tsinghua.edu.cn/alpine'
              fi
              printf \"%s/$v/main\\n%s/$v/community\\n\" \"$mirror\" \"$mirror\" > /etc/apk/repositories
              echo \"已修复仓库版本为 $v\"
            else
              echo \"仓库版本正确，无需修复\"
            fi
            cat /etc/apk/repositories
            """
            let r = try await ISHBridge.shared.execute(script)
            appendLog(r.output)
            if r.isSuccess {
                await refreshCurrentMirror()
                phase = .done("仓库版本已修复")
            } else {
                phase = .failed("修复失败 (exit \(r.exitCode))")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// 读取当前镜像源名称
    func refreshCurrentMirror() async {
        do {
            let r = try await ISHBridge.shared.execute("cat /etc/apk/repositories 2>&1")
            let content = r.output
            for (name, url) in Self.mirrorOptions {
                if content.contains(url) {
                    currentMirrorName = name
                    return
                }
            }
            currentMirrorName = "自定义"
        } catch {
            currentMirrorName = "未知"
        }
    }

    /// 切换到指定镜像源
    func switchMirror(to url: String, name: String) async {
        phase = .backingUp // 复用 busy 状态
        appendLog("▸ 切换镜像源到 \(name)")
        do {
            // 优先从 /etc/os-release 读取实际版本号，回退到 repositories 文件
            let versionR = try await ISHBridge.shared.execute(
                "v=$(grep -oE 'VERSION_ID=v?[0-9]+\\.[0-9]+' /etc/os-release 2>/dev/null | grep -oE 'v[0-9]+\\.[0-9]+' | head -1); "
                + "[ -z \"$v\" ] && v=$(grep -oE 'v[0-9]+\\.[0-9]+' /etc/apk/repositories 2>/dev/null | head -1); "
                + "[ -z \"$v\" ] && v='v3.21'; "
                + "echo $v"
            )
            let version = versionR.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !version.isEmpty else {
                phase = .failed("无法识别当前 Alpine 版本号")
                return
            }
            appendLog("Alpine 版本：\(version)")

            let repos = """
            \(url)/\(version)/main
            \(url)/\(version)/community
            """
            // 用 printf 写入，避免 heredoc 转义问题
            let escapedRepos = repos.replacingOccurrences(of: "/", with: "\\/")
            let r = try await ISHBridge.shared.execute(
                "printf '\(escapedRepos)\\n' > /etc/apk/repositories && cat /etc/apk/repositories"
            )
            appendLog(r.output)
            if r.isSuccess {
                currentMirrorName = name
                appendLog("✓ 已切换到 \(name)")
                phase = .done("镜像源已切换到 \(name)")
            } else {
                phase = .failed("换源失败 (exit \(r.exitCode))")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Log

    func clearLog() {
        logLines.removeAll()
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
    }

    // MARK: - Parsing

    private func parseUpgradable(_ output: String) -> [String] {
        output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Date formatting

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()
}
