//
//  ModelPricing.swift
//  Velum
//
//  照抄 Visor ModelPricing：模型单价表 + 成本计算
//  用户金融级安全需求：成本透明可审计
//

import Foundation

/// 模型单价（USD / 1M tokens）
struct ModelPricing: Codable, Sendable, Hashable {
    let modelId: String
    let inputPricePerMTokensUSD: Double
    let outputPricePerMTokensUSD: Double
    /// 货币（默认 USD）
    let currency: String

    /// 计算一次对话的费用（USD）
    func costUSD(inputTokens: Int, outputTokens: Int) -> Double {
        let input = Double(inputTokens) / 1_000_000.0 * inputPricePerMTokensUSD
        let output = Double(outputTokens) / 1_000_000.0 * outputPricePerMTokensUSD
        return input + output
    }
}

/// 模型单价表：启动时从 model_pricing.json 加载，兜底内置硬编码
nonisolated final class ModelPricingTable: @unchecked Sendable {
    private var table: [String: ModelPricing]
    private let queue = DispatchQueue(label: "com.lyrastudio.Velum.ModelPricingTable")

    init(table: [String: ModelPricing]) {
        self.table = table
    }

    static let shared: ModelPricingTable = {
        let url = Bundle.main.url(forResource: "model_pricing", withExtension: "json")
            ?? Bundle.main.url(forResource: "model_pricing", withExtension: "json", subdirectory: "Pricing")
        let table: [String: ModelPricing]
        if let url, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: ModelPricing].self, from: data) {
            table = decoded
        } else {
            // 兜底：内置硬编码（照抄 Visor 2026-07-07 实测数据）
            table = ModelPricingTable.builtinFallback
        }
        return ModelPricingTable(table: table)
    }()

    func pricing(for modelId: String) -> ModelPricing? {
        queue.sync { table[modelId] }
    }

    func costUSD(modelId: String, inputTokens: Int, outputTokens: Int) -> Double {
        guard let p = pricing(for: modelId) else { return 0 }
        return p.costUSD(inputTokens: inputTokens, outputTokens: outputTokens)
    }

    /// 内置兜底单价表（照抄 Visor，2026-07-07 OpenRouter 实测数据）
    /// 未知模型返回 0 成本（不阻塞流，但 costUSD 显示为 0）
    static let builtinFallback: [String: ModelPricing] = [
        "moonshotai/kimi-k2.7-code": ModelPricing(
            modelId: "moonshotai/kimi-k2.7-code",
            inputPricePerMTokensUSD: 0.95,
            outputPricePerMTokensUSD: 4.00,
            currency: "USD"
        ),
        "nex-agi/nex-n2-pro": ModelPricing(
            modelId: "nex-agi/nex-n2-pro",
            inputPricePerMTokensUSD: 0.25,
            outputPricePerMTokensUSD: 1.00,
            currency: "USD"
        ),
        "nex-agi/nex-n2-mini": ModelPricing(
            modelId: "nex-agi/nex-n2-mini",
            inputPricePerMTokensUSD: 0.025,
            outputPricePerMTokensUSD: 0.10,
            currency: "USD"
        ),
        "qwen/qwen3.7-plus": ModelPricing(
            modelId: "qwen/qwen3.7-plus",
            inputPricePerMTokensUSD: 0.32,
            outputPricePerMTokensUSD: 1.28,
            currency: "USD"
        ),
        "minimax/minimax-m3": ModelPricing(
            modelId: "minimax/minimax-m3",
            inputPricePerMTokensUSD: 0.30,
            outputPricePerMTokensUSD: 1.20,
            currency: "USD"
        ),
        "stepfun/step-3.7-flash": ModelPricing(
            modelId: "stepfun/step-3.7-flash",
            inputPricePerMTokensUSD: 0.20,
            outputPricePerMTokensUSD: 1.15,
            currency: "USD"
        ),
        "x-ai/grok-build-0.1": ModelPricing(
            modelId: "x-ai/grok-build-0.1",
            inputPricePerMTokensUSD: 1.00,
            outputPricePerMTokensUSD: 2.00,
            currency: "USD"
        ),
        "x-ai/grok-4.3": ModelPricing(
            modelId: "x-ai/grok-4.3",
            inputPricePerMTokensUSD: 1.25,
            outputPricePerMTokensUSD: 2.50,
            currency: "USD"
        ),
        "xiaomi/mimo-v2.5": ModelPricing(
            modelId: "xiaomi/mimo-v2.5",
            inputPricePerMTokensUSD: 0.105,
            outputPricePerMTokensUSD: 0.28,
            currency: "USD"
        ),
        "tencent/hy3": ModelPricing(
            modelId: "tencent/hy3",
            inputPricePerMTokensUSD: 0.14,
            outputPricePerMTokensUSD: 0.58,
            currency: "USD"
        ),
        "z-ai/glm-5.2": ModelPricing(
            modelId: "z-ai/glm-5.2",
            inputPricePerMTokensUSD: 0.91,
            outputPricePerMTokensUSD: 2.86,
            currency: "USD"
        ),
        "nvidia/nemotron-3-ultra-550b-a55b": ModelPricing(
            modelId: "nvidia/nemotron-3-ultra-550b-a55b",
            inputPricePerMTokensUSD: 0.50,
            outputPricePerMTokensUSD: 2.20,
            currency: "USD"
        ),
        "qwen/qwen3.7-max": ModelPricing(
            modelId: "qwen/qwen3.7-max",
            inputPricePerMTokensUSD: 1.25,
            outputPricePerMTokensUSD: 3.75,
            currency: "USD"
        ),
        "inclusionai/ring-2.6-1t": ModelPricing(
            modelId: "inclusionai/ring-2.6-1t",
            inputPricePerMTokensUSD: 0.075,
            outputPricePerMTokensUSD: 0.625,
            currency: "USD"
        ),
        "poolside/laguna-m.1": ModelPricing(
            modelId: "poolside/laguna-m.1",
            inputPricePerMTokensUSD: 0.20,
            outputPricePerMTokensUSD: 0.40,
            currency: "USD"
        ),
        "deepseek/deepseek-v4-pro": ModelPricing(
            modelId: "deepseek/deepseek-v4-pro",
            inputPricePerMTokensUSD: 0.435,
            outputPricePerMTokensUSD: 0.87,
            currency: "USD"
        ),
        "deepseek/deepseek-v4-flash": ModelPricing(
            modelId: "deepseek/deepseek-v4-flash",
            inputPricePerMTokensUSD: 0.0983,
            outputPricePerMTokensUSD: 0.1966,
            currency: "USD"
        ),
        "xiaomi/mimo-v2.5-pro": ModelPricing(
            modelId: "xiaomi/mimo-v2.5-pro",
            inputPricePerMTokensUSD: 0.435,
            outputPricePerMTokensUSD: 0.87,
            currency: "USD"
        ),
        "inclusionai/ling-2.6-flash": ModelPricing(
            modelId: "inclusionai/ling-2.6-flash",
            inputPricePerMTokensUSD: 0.01,
            outputPricePerMTokensUSD: 0.03,
            currency: "USD"
        ),
        "arcee-ai/trinity-large-thinking": ModelPricing(
            modelId: "arcee-ai/trinity-large-thinking",
            inputPricePerMTokensUSD: 0.25,
            outputPricePerMTokensUSD: 0.80,
            currency: "USD"
        ),
    ]
}
