//
//  AppForm.swift
//  Velum
//
//  第三方 App 的三种形态。
//
//  设计前提：iOS 上"可执行动态逻辑"只有两条合规路径——
//    1. WKWebView：Apple 的 WebKit 进程对 JS 做 JIT（H5/JS 由此获得真正的 JIT）
//    2. Linux Container：iSH 解释执行 Linux ELF（非原生执行，合规）
//  三种形态是这两条路径的组合：
//    - elfBridge  ：Linux ELF（Container 出逻辑）+ CLI↔H5 桥接图形化（WKWebView 出 UI）
//    - webService ：Linux 内本地 web 服务（Container）+ URL 书签（WKWebView 渲染）
//    - h5Package  ：纯 H5/JS 包，WKWebView 直接当 JIT 引擎（不依赖 Linux）
//
//  详见 doc&&blueprints/92-third-party-app-program.md
//

import Foundation

/// 第三方 App 形态。
public enum AppForm: String, Codable, CaseIterable, Sendable, Hashable {
    /// 形态 1：原生 Linux ELF + CLI↔H5 桥接图形化。
    case elfBridge
    /// 形态 2：Linux 本地 web 服务 + URL 书签。
    case webService
    /// 形态 3：H5/JS 包，WKWebView 直接作为 JIT 引擎。
    case h5Package

    public var displayName: String {
        switch self {
        case .elfBridge:  return "ELF 桥接"
        case .webService: return "Web 服务"
        case .h5Package:  return "H5 包"
        }
    }

    public var blurb: String {
        switch self {
        case .elfBridge:  return "Linux ELF 后端，经 CLI↔H5 桥接提供图形界面"
        case .webService: return "Linux 内本地 web 服务，App 即一个 URL 书签"
        case .h5Package:  return "纯 H5/JS 包，WKWebView 直接运行（无需 Linux）"
        }
    }

    /// 启动器/窗口默认图标（SF Symbol）。
    public var systemImage: String {
        switch self {
        case .elfBridge:  return "terminal.fill"
        case .webService: return "network"
        case .h5Package:  return "shippingbox.fill"
        }
    }
}
