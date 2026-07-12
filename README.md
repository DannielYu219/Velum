# Velum

基于 [iSH](https://github.com/ish-app/ish) 构建的 iOS 桌面环境，为 iPad 打造完整的 Linux 桌面体验。

## 特性

- **桌面环境** — 纯 SwiftUI 实现，采用 Liquid Glass 设计语言（iOS 26+；低于 iOS 26 自动降级为 Blur）
- **多窗口管理** — 可拖拽、可缩放、最大化、最小化到 Dock，窗口聚焦与层级管理，打开/关闭动画
- **Dock & Launcher** — 底部 Dock 快速启动，点击 Launcher 图标展开应用网格
- **TopBar** — 顶部状态栏，窗口最大化时自动隐藏
- **内置应用**
  - **Terminal** — 完整终端，基于 iSH 内核
  - **Files** — 文件管理器
  - **Settings** — 系统设置（外观 / 字体 / 光标 / 键盘 / 启动 / rootfs / 关于）
  - **Agent** — AI 助手，支持 MCP 协议
  - **About** — 关于页面
- **MCP 协议** — JSON-RPC over TCP（localhost:8765），支持 shell 执行、文件读写、进程查询、系统信息、应用调度
- **首次启动自动配置** — 自动切换国内镜像源（清华 TUNA）、`apk update`、预装 python3 / py3-pip / bash / curl / wget / git
- **rootfs 管理** — 检查更新、apk upgrade、备份、恢复、镜像源切换、修复仓库版本

## 系统要求

- iPadOS 17.0+（主要面向 iPad）
- Xcode 16+ 构建
- iOS 26+ 体验完整 Liquid Glass；低于 iOS 26 使用 Blur 兜底

## 构建

1. 克隆仓库
2. 用 Xcode 打开 `Velum/Velum.xcodeproj`
3. 选择 **Velum** scheme，连接 iPad
4. `⌘R` 构建运行

> 依赖（meson / ninja）会在 Xcode Build Phase 中自动构建，无需手动配置。

## 项目结构

```
Velum/
├── Velum/                      # iOS App（SwiftUI 桌面层）
│   ├── Desktop/                # 桌面 shell
│   │   ├── ContentView.swift   # 主界面（ZStack 多层布局）
│   │   ├── Dock.swift          # 底部 Dock
│   │   ├── TopBar.swift        # 顶部状态栏
│   │   ├── LauncherView.swift  # 应用网格
│   │   ├── WindowManager.swift # 窗口管理（多窗口/拖拽/缩放/最小化）
│   │   ├── GlassCompat.swift   # Liquid Glass / Blur 兼容层
│   │   ├── AppHostView.swift   # 应用宿主视图
│   │   ├── TerminalView.swift  # Terminal UIViewController 包装
│   │   └── FirstBootSetup.swift# 首次启动配置
│   ├── Apps/                   # 内置应用
│   │   ├── AgentApp/           # AI 助手（AgentView / MCPClient / MockLLM）
│   │   └── SettingsApp/        # 设置（SettingsView / RootfsManager）
│   ├── ControlPlane/           # 控制平面
│   │   ├── VelumAction.swift   # 动作枚举
│   │   ├── VelumControl.swift  # 单例 + AsyncStream
│   │   └── MCPServer.swift     # MCP JSON-RPC Server
│   ├── HostBridge/             # iSH 桥接
│   │   ├── ISHBridge.swift     # Swift async facade
│   │   └── ISHFsBridge.h/.m    # Obj-C 文件系统 facade
│   └── Kernel/                 # 内核状态管理
├── app/                        # iSH Obj-C 层
│   ├── TerminalViewController  # 终端视图控制器
│   ├── UserPreferences         # 用户偏好
│   ├── AppDelegate             # 应用委托
│   └── ...                     # iSH 原有代码
├── emu/                        # iSH 模拟器核心（CPU 翻译）
├── fs/                         # iSH 文件系统
├── kernel/                     # iSH 内核
└── deps/                       # 依赖（libarchive, hterm...）
```

## 致谢

本项目基于 [iSH](https://github.com/ish-app/ish) 构建，感谢 Theodore Dubois 及 iSH 社区所有贡献者。

## 许可证

本项目沿用 iSH 的 [GPL-3.0](LICENSE) 许可证。通过 Apple App Store 分发的额外条款见 [LICENSE.IOS](LICENSE.IOS)。
