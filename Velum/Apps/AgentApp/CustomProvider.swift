//
//  CustomProvider.swift
//  Velum
//
//  照抄 Visor CustomProvider：自定义 OpenAI 兼容服务商配置 + 注册表
//  适配 Velum：用 AgentKeychain 替代 KeychainStore
//

import Foundation
import os.log

/// 自定义服务商的单个模型定义
struct CustomModelInfo: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var displayName: String
    var supportsVision: Bool
}

/// 自定义服务商分组配置（OpenAI 兼容格式）
struct CustomProviderConfig: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var baseURL: String
    var models: [CustomModelInfo]
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        models: [CustomModelInfo] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.models = models
        self.createdAt = createdAt
    }

    /// Keychain 中存储 API Key 的 account 名
    var apiKeyAccount: String { "custom_provider_\(id.uuidString)" }

    /// 构造命名空间化的模型 ID（用于与 OpenRouter 模型区分）
    func namespacedModelId(_ rawModelId: String) -> String {
        "custom::\(id.uuidString)::\(rawModelId)"
    }
}

/// 解析后的 provider 引用：携带原始 modelId 传给 provider.stream
struct ResolvedProvider: Sendable {
    let provider: ModelProvider
    let modelId: String
    let displayName: String
}

/// 自定义服务商注册表（照抄 Visor，适配 Velum AgentKeychain）
///
/// - 配置存 UserDefaults（非敏感数据）
/// - API Key 存 AgentKeychain（按 provider id 命名 account）
nonisolated final class CustomProviderRegistry: @unchecked Sendable {

    static let shared = CustomProviderRegistry()

    private static let storageKey = "agent.customProviderConfigs"

    private let queue = DispatchQueue(label: "com.lyrastudio.Velum.CustomProviderRegistry")
    private var configs: [CustomProviderConfig] = []
    nonisolated private let logger = Logger(subsystem: "com.lyrastudio.Velum", category: "CustomProviderRegistry")

    private init() {
        reload()
    }

    // MARK: - 持久化

    func reload() {
        queue.sync {
            if let data = UserDefaults.standard.data(forKey: Self.storageKey),
               let decoded = try? JSONDecoder().decode([CustomProviderConfig].self, from: data) {
                configs = decoded
            } else {
                configs = []
            }
        }
    }

    func save(_ configs: [CustomProviderConfig]) {
        queue.sync {
            self.configs = configs
            if let data = try? JSONEncoder().encode(configs) {
                UserDefaults.standard.set(data, forKey: Self.storageKey)
            }
        }
    }

    func allConfigs() -> [CustomProviderConfig] {
        queue.sync { configs }
    }

    // MARK: - API Key（AgentKeychain）

    func apiKey(for providerId: UUID) -> String? {
        AgentKeychain.get(account: "custom_provider_\(providerId.uuidString)")
    }

    func setAPIKey(_ key: String, for providerId: UUID) throws {
        try AgentKeychain.set(key, account: "custom_provider_\(providerId.uuidString)")
    }

    func deleteAPIKey(for providerId: UUID) {
        AgentKeychain.delete(account: "custom_provider_\(providerId.uuidString)")
    }

    // MARK: - 解析

    /// 根据命名空间化的 modelId 解析出 provider + 原始 modelId
    /// - Parameter modelId: 如 "custom::{uuid}::{rawModelId}"
    func resolve(_ modelId: String) -> ResolvedProvider? {
        guard modelId.hasPrefix("custom::") else { return nil }
        let remainder = String(modelId.dropFirst("custom::".count))
        guard let sepRange = remainder.range(of: "::") else { return nil }
        let providerUUIDString = String(remainder[remainder.startIndex..<sepRange.lowerBound])
        let rawModelId = String(remainder[sepRange.upperBound...])

        guard let providerId = UUID(uuidString: providerUUIDString) else { return nil }

        var config: CustomProviderConfig?
        queue.sync { config = configs.first { $0.id == providerId } }
        guard let config else { return nil }

        guard let modelInfo = config.models.first(where: { $0.id == rawModelId }) else {
            return nil
        }

        guard let apiKey = AgentKeychain.get(account: config.apiKeyAccount), !apiKey.isEmpty else {
            return nil
        }

        let client = OpenAICompatibleClient(baseURL: config.baseURL, apiKey: apiKey)
        return ResolvedProvider(
            provider: client,
            modelId: rawModelId,
            displayName: "\(config.name) · \(modelInfo.displayName)"
        )
    }

    func isCustomModel(_ modelId: String) -> Bool {
        modelId.hasPrefix("custom::")
    }

    func allCustomModels() -> [(config: CustomProviderConfig, model: CustomModelInfo)] {
        queue.sync {
            configs.flatMap { config in
                config.models.map { (config, $0) }
            }
        }
    }

    func displayName(for modelId: String) -> String? {
        guard let resolved = resolve(modelId) else { return nil }
        return resolved.displayName
    }
}
