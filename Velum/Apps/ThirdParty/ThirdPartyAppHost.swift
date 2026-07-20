//
//  ThirdPartyAppHost.swift
//  Velum
//
//  第三方 App 宿主：按 manifest.form 把窗口内容分发到三种形态视图。
//  由 AppHostView 在 window.thirdPartyId 非空时调用。
//

import SwiftUI

struct ThirdPartyAppHost: View {
    let appId: String

    var body: some View {
        if let manifest = AppRegistry.shared.app(appId) {
            switch manifest.form {
            case .h5Package:
                H5PackageView(manifest: manifest)
            case .webService:
                WebServiceView(manifest: manifest)
            case .elfBridge:
                ELFBridgeView(manifest: manifest)
            }
        } else {
            notInstalled
        }
    }

    private var notInstalled: some View {
        VStack(spacing: 12) {
            Image(systemName: "questionmark.app.dashed")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("App 未安装或已被移除")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(appId)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
