//
//  ModelCatalog.swift
//  Velum
//
//  照抄 Visor OpenRouterModels：OpenRouter 预设模型目录
//

import Foundation

/// OpenRouter 模型目录（照抄 Visor）
nonisolated enum ModelCatalog {
    static let defaultModelId = "xiaomi/mimo-v2.5"

    struct ModelInfo: Identifiable, Hashable, Sendable {
        let id: String
        let displayName: String
        let provider: String
        let tier: Tier
        let supportsVision: Bool

        enum Tier: String, Sendable, CaseIterable {
            case flagship
            case pro
            case fast
        }
    }

    static let catalog: [ModelInfo] = [
        // MARK: 多模态模型
        .init(id: "moonshotai/kimi-k2.7-code",
              displayName: "Kimi K2.7 Code",
              provider: "moonshotai",
              tier: .flagship,
              supportsVision: true),
        .init(id: "nex-agi/nex-n2-pro",
              displayName: "Nex N2 Pro",
              provider: "nex-agi",
              tier: .pro,
              supportsVision: true),
        .init(id: "nex-agi/nex-n2-mini",
              displayName: "Nex N2 Mini",
              provider: "nex-agi",
              tier: .fast,
              supportsVision: true),
        .init(id: "qwen/qwen3.7-plus",
              displayName: "Qwen3.7 Plus",
              provider: "qwen",
              tier: .fast,
              supportsVision: true),
        .init(id: "minimax/minimax-m3",
              displayName: "MiniMax M3",
              provider: "minimax",
              tier: .pro,
              supportsVision: true),
        .init(id: "stepfun/step-3.7-flash",
              displayName: "Step 3.7 Flash",
              provider: "stepfun",
              tier: .fast,
              supportsVision: true),
        .init(id: "x-ai/grok-build-0.1",
              displayName: "Grok Build 0.1",
              provider: "x-ai",
              tier: .pro,
              supportsVision: true),
        .init(id: "x-ai/grok-4.3",
              displayName: "Grok 4.3",
              provider: "x-ai",
              tier: .flagship,
              supportsVision: true),
        .init(id: "xiaomi/mimo-v2.5",
              displayName: "MiMo V2.5",
              provider: "xiaomi",
              tier: .fast,
              supportsVision: true),

        // MARK: 文本模型
        .init(id: "tencent/hy3:free",
              displayName: "Hy3 (免费)",
              provider: "tencent",
              tier: .fast,
              supportsVision: false),
        .init(id: "tencent/hy3",
              displayName: "Tencent Hy3",
              provider: "tencent",
              tier: .fast,
              supportsVision: false),
        .init(id: "z-ai/glm-5.2",
              displayName: "GLM 5.2",
              provider: "z-ai",
              tier: .flagship,
              supportsVision: false),
        .init(id: "nvidia/nemotron-3-ultra-550b-a55b:free",
              displayName: "Nemotron 3 Ultra (免费)",
              provider: "nvidia",
              tier: .fast,
              supportsVision: false),
        .init(id: "nvidia/nemotron-3-ultra-550b-a55b",
              displayName: "Nemotron 3 Ultra",
              provider: "nvidia",
              tier: .flagship,
              supportsVision: false),
        .init(id: "qwen/qwen3.7-max",
              displayName: "Qwen3.7 Max",
              provider: "qwen",
              tier: .flagship,
              supportsVision: false),
        .init(id: "inclusionai/ring-2.6-1t",
              displayName: "Ring 2.6 1T",
              provider: "inclusionai",
              tier: .fast,
              supportsVision: false),
        .init(id: "poolside/laguna-m.1:free",
              displayName: "Laguna M.1 (免费)",
              provider: "poolside",
              tier: .fast,
              supportsVision: false),
        .init(id: "poolside/laguna-m.1",
              displayName: "Laguna M.1",
              provider: "poolside",
              tier: .fast,
              supportsVision: false),
        .init(id: "deepseek/deepseek-v4-pro",
              displayName: "DeepSeek V4 Pro",
              provider: "deepseek",
              tier: .flagship,
              supportsVision: false),
        .init(id: "deepseek/deepseek-v4-flash",
              displayName: "DeepSeek V4 Flash",
              provider: "deepseek",
              tier: .fast,
              supportsVision: false),
        .init(id: "xiaomi/mimo-v2.5-pro",
              displayName: "MiMo V2.5 Pro",
              provider: "xiaomi",
              tier: .pro,
              supportsVision: false),
        .init(id: "inclusionai/ling-2.6-flash",
              displayName: "Ling 2.6 Flash",
              provider: "inclusionai",
              tier: .fast,
              supportsVision: false),
        .init(id: "arcee-ai/trinity-large-thinking",
              displayName: "Trinity Large Thinking",
              provider: "arcee-ai",
              tier: .fast,
              supportsVision: false),
    ]

    static func find(_ id: String) -> ModelInfo? {
        catalog.first { $0.id == id }
    }

    /// 失败降级：当前模型不可用时返回兜底
    static func fallback(from unavailable: String) -> ModelInfo {
        if let alt = catalog.first(where: { $0.id != unavailable && $0.tier == .fast }) {
            return alt
        }
        return catalog[0]
    }
}
