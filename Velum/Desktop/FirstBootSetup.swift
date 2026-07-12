//
//  FirstBootSetup.swift
//  Velum
//
//  首次启动自动配置：安装 python3 等预装包 + 初始化用户环境。
//  通过 ISHBridge 在 iSH 内执行 apk 和 shell 命令。
//

import Foundation
import SwiftUI

@MainActor
final class FirstBootSetup: ObservableObject {

    // MARK: - Published state

    @Published var phase: Phase = .pending
    @Published var logLines: [String] = []

    // MARK: - Types

    enum Phase: Equatable {
        case pending
        case switchingMirror
        case updatingRepos
        case installingPackages
        case configuringEnv
        case completed
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .switchingMirror, .updatingRepos, .installingPackages, .configuringEnv: return true
            default: return false
            }
        }

        var label: String {
            switch self {
            case .pending: return "等待开始"
            case .switchingMirror: return "正在切换国内镜像源…"
            case .updatingRepos: return "正在更新软件源…"
            case .installingPackages: return "正在安装预装软件包…"
            case .configuringEnv: return "正在配置环境…"
            case .completed: return "配置完成"
            case .failed(let msg): return "失败：\(msg)"
            }
        }
    }

    // MARK: - Constants

    /// 首次启动需要安装的包列表
    static let presetPackages = ["python3", "py3-pip", "bash", "curl", "wget", "git"]

    private let firstBootKey = "velum.firstBootSetupCompleted"
    private let defaults = UserDefaults.standard

    // MARK: - Public

    var isNeeded: Bool {
        !defaults.bool(forKey: firstBootKey)
    }

    /// 执行首次启动配置。如果已经完成则跳过。
    func runIfNeeded() async {
        guard isNeeded else {
            phase = .completed
            return
        }

        // 1. 切换国内镜像源（官方 CDN 在国内访问慢）
        phase = .switchingMirror
        appendLog("▸ 检测并切换国内镜像源")
        do {
            let r = try await ISHBridge.shared.execute(Self.mirrorSwitchScript)
            appendLog(r.output)
            if !r.isSuccess {
                appendLog("换源脚本返回非零退出码 \(r.exitCode)（非致命，继续使用原源）")
            }
        } catch {
            appendLog("换源异常：\(error.localizedDescription)（非致命，继续）")
        }

        // 2. 更新软件源
        phase = .updatingRepos
        appendLog("▸ apk update")
        do {
            let r = try await ISHBridge.shared.execute("apk update 2>&1")
            appendLog(r.output)
            guard r.isSuccess else {
                phase = .failed("apk update 失败 (exit \(r.exitCode))")
                return
            }
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        // 3. 安装预装包
        phase = .installingPackages
        let pkgs = Self.presetPackages.joined(separator: " ")
        appendLog("▸ apk add \(pkgs)")
        do {
            let r = try await ISHBridge.shared.execute("apk add \(pkgs) 2>&1")
            appendLog(r.output)
            guard r.isSuccess else {
                phase = .failed("安装预装包失败 (exit \(r.exitCode))")
                return
            }
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        // 4. 配置环境
        phase = .configuringEnv
        appendLog("▸ 配置用户环境…")
        do {
            let r = try await ISHBridge.shared.execute(Self.configScript)
            appendLog(r.output)
            if !r.isSuccess {
                appendLog("配置脚本返回非零退出码 \(r.exitCode)，但已继续")
            }
        } catch {
            appendLog("配置脚本异常：\(error.localizedDescription)（非致命）")
        }

        // 5. 标记完成
        phase = .completed
        appendLog("✓ 首次启动配置完成")
        defaults.set(true, forKey: firstBootKey)
    }

    /// 重置首次启动标志（用于调试/重置）。
    func reset() {
        defaults.set(false, forKey: firstBootKey)
        phase = .pending
        logLines.removeAll()
    }

    // MARK: - Private

    private func appendLog(_ line: String) {
        logLines.append(line)
    }

    /// 换源脚本：从 /etc/os-release 读取实际 Alpine 版本，替换为清华 TUNA 镜像
    private static let mirrorSwitchScript: String = {
        let mirrors = FirstBootSetup.chinaMirrors.map { "\($0.url)/$v/main\n\($0.url)/$v/community" }
                                       .joined(separator: "\n")
        return [
            "set -e",
            "# 从 /etc/os-release 读取实际 Alpine 版本号",
            "v=$(grep -oE 'VERSION_ID=v?[0-9]+\\.[0-9]+' /etc/os-release 2>/dev/null | grep -oE 'v[0-9]+\\.[0-9]+' | head -1)",
            "if [ -z \"$v\" ]; then",
            "  v=$(cat /etc/apk/repositories 2>/dev/null | grep -oE 'v[0-9]+\\.[0-9]+' | head -1)",
            "fi",
            "if [ -z \"$v\" ]; then",
            "  v='v3.21'",
            "  echo \"未识别版本，回退到 $v\"",
            "fi",
            "echo \"检测到 Alpine $v\"",
            "cat > /etc/apk/repositories << REPO_EOF",
            "\(mirrors)",
            "REPO_EOF",
            "echo \"已切换到清华 TUNA 镜像 (Alpine $v)\"",
            "cat /etc/apk/repositories",
        ].joined(separator: "\n")
    }()

    /// 国内镜像源列表（按优先级排序）
    static let chinaMirrors: [(name: String, url: String)] = [
        ("清华大学 TUNA", "https://mirrors.tuna.tsinghua.edu.cn/alpine"),
        ("中科大 USTC",   "https://mirrors.ustc.edu.cn/alpine"),
        ("阿里云",        "https://mirrors.aliyun.com/alpine"),
    ]

    /// 官方源
    static let officialMirror = "https://dl-cdn.alpinelinux.org/alpine"

    /// 环境配置脚本：创建目录、写 .profile、设置别名
    private static let configScript: String = {
        let profileLines = [
            "",
            "# Velum environment",
            "export PS1='velum:\\w# '",
            "export PATH=$PATH:/usr/local/bin",
            "alias ll='ls -la'",
            "alias la='ls -la'",
            "alias ..='cd ..'",
            "alias ...='cd ../..'",
            "alias python=python3",
            "alias pip='pip3'",
        ].joined(separator: "\n")

        return [
            "set -e",
            "mkdir -p /root/Documents /root/Downloads /root/Projects /root/.config",
            "",
            "if ! grep -q 'Velum environment' /root/.profile 2>/dev/null; then",
            "  printf '\\n%s\\n' '\(profileLines)' >> /root/.profile",
            "fi",
            "",
            "echo 'velum' > /etc/hostname 2>/dev/null || true",
            "",
            "echo 'Environment configured.'",
        ].joined(separator: "\n")
    }()
}
