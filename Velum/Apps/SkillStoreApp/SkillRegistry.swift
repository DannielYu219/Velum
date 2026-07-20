//
//  SkillRegistry.swift
//  Velum
//
//  Agent Skill 注册表：管理已安装的 Skill
//  仿照 CustomProviderRegistry 模式：UserDefaults 持久化 + 线程安全队列
//

import Foundation
import Combine

/// 已安装 Skill 的注册表（全局单例）
@MainActor
final class SkillRegistry: ObservableObject {

    static let shared = SkillRegistry()

    /// 已安装的 Skill ID 列表（按安装顺序）
    @Published private(set) var installedSkillIds: [String] = []

    /// UserDefaults 持久化 key
    private static let storageKey = "agent.installedSkills"

    private init() {
        load()
    }

    // MARK: - 查询

    /// 已安装的 SkillDefinition 列表（解析后的完整对象）
    var installedSkills: [SkillDefinition] {
        installedSkillIds.compactMap { SkillCatalog.find(id: $0) }
    }

    /// 是否已安装
    func isInstalled(_ skillId: String) -> Bool {
        installedSkillIds.contains(skillId)
    }

    /// 已安装数量
    var count: Int { installedSkillIds.count }

    // MARK: - 安装 / 卸载

    /// 安装 Skill
    func install(_ skillId: String) {
        guard !installedSkillIds.contains(skillId) else { return }
        guard SkillCatalog.find(id: skillId) != nil else { return }
        installedSkillIds.append(skillId)
        save()
    }

    /// 卸载 Skill
    func uninstall(_ skillId: String) {
        installedSkillIds.removeAll { $0 == skillId }
        save()
    }

    /// 切换安装状态
    @discardableResult
    func toggle(_ skillId: String) -> Bool {
        if isInstalled(skillId) {
            uninstall(skillId)
            return false
        } else {
            install(skillId)
            return true
        }
    }

    /// 卸载全部
    func uninstallAll() {
        installedSkillIds.removeAll()
        save()
    }

    // MARK: - Agent 集成

    /// 合并所有已安装 Skill 的 system prompt（用于注入 AgentRuntime）
    /// 返回 nil 表示没有已安装的 Skill
    func composedSystemPrompt() -> String? {
        let skills = installedSkills
        guard !skills.isEmpty else { return nil }

        let fragments = skills.map { skill in
            """
            ---

            # 已激活 Skill：\(skill.displayName)

            \(skill.systemPrompt)
            """
        }

        let header = """
        # 已安装的 Skill 能力包

        以下 Skill 已被用户安装，请在适用场景下主动运用这些能力。当用户的请求匹配某个 Skill 的范畴时，严格遵循该 Skill 的指令执行。

        """

        return header + fragments.joined(separator: "\n\n")
    }

    // MARK: - 持久化

    private func load() {
        if let arr = UserDefaults.standard.array(forKey: Self.storageKey) as? [String] {
            installedSkillIds = arr.filter { SkillCatalog.find(id: $0) != nil }
        }
    }

    private func save() {
        UserDefaults.standard.set(installedSkillIds, forKey: Self.storageKey)
    }
}
