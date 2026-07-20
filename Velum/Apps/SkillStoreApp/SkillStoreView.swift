//
//  SkillStoreView.swift
//  Velum
//
//  Agent Skill 商店 UI：浏览 / 安装 / 卸载 / 查看详情
//  设计风格：照抄 AgentSettingsView（NavigationStack + List + insetGrouped + 透明背景）
//

import SwiftUI

struct SkillStoreView: View {
    @ObservedObject private var registry = SkillRegistry.shared
    @State private var selectedCategory: SkillCategory? = nil
    @State private var searchText: String = ""
    @State private var detailSkill: SkillDefinition? = nil

    var body: some View {
        NavigationStack {
            List {
                // 已安装区
                if !registry.installedSkills.isEmpty {
                    installedSection
                }

                // 分类浏览
                ForEach(filteredGroups, id: \.0) { cat, skills in
                    Section {
                        ForEach(skills) { skill in
                            SkillRow(
                                skill: skill,
                                isInstalled: registry.isInstalled(skill.id),
                                onToggle: { registry.toggle(skill.id) },
                                onTap: { detailSkill = skill }
                            )
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: cat.icon)
                                .font(.caption)
                            Text(cat.label)
                                .font(.caption.weight(.semibold))
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .navigationTitle("Skill 商店")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索 Skill")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("分类", selection: $selectedCategory) {
                            Text("全部分类").tag(SkillCategory?.none)
                            ForEach(SkillCategory.allCases, id: \.self) { cat in
                                Text(cat.label).tag(SkillCategory?.some(cat))
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .sheet(item: $detailSkill) { skill in
                SkillDetailSheet(skill: skill, isInstalled: registry.isInstalled(skill.id)) {
                    registry.toggle(skill.id)
                }
            }
        }
    }

    // MARK: - 已安装区

    private var installedSection: some View {
        Section {
            ForEach(registry.installedSkills) { skill in
                SkillRow(
                    skill: skill,
                    isInstalled: true,
                    onToggle: { registry.toggle(skill.id) },
                    onTap: { detailSkill = skill }
                )
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text("已安装（\(registry.count)）")
                    .font(.caption.weight(.semibold))
            }
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - 过滤逻辑

    private var filteredGroups: [(SkillCategory, [SkillDefinition])] {
        SkillCatalog.grouped().map { (cat, skills) in
            let filtered = skills.filter { skill in
                // 分类过滤
                if let selected = selectedCategory, cat != selected { return false }
                // 搜索过滤
                if searchText.isEmpty { return true }
                return skill.displayName.localizedCaseInsensitiveContains(searchText)
                    || skill.description.localizedCaseInsensitiveContains(searchText)
                    || skill.name.localizedCaseInsensitiveContains(searchText)
            }
            return (cat, filtered)
        }
        .filter { !$0.1.isEmpty }
    }
}

// MARK: - SkillRow（单行卡片）

private struct SkillRow: View {
    let skill: SkillDefinition
    let isInstalled: Bool
    let onToggle: () -> Void
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // 图标
            Image(systemName: skill.icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .liquidGlass(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))

            // 文本
            VStack(alignment: .leading, spacing: 3) {
                Text(skill.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(skill.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            // 安装按钮
            Button(action: onToggle) {
                Image(systemName: isInstalled ? "checkmark.circle.fill" : "plus.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(isInstalled ? Color.green : Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }
}

// MARK: - SkillDetailSheet（详情弹窗）

private struct SkillDetailSheet: View {
    let skill: SkillDefinition
    let isInstalled: Bool
    let onToggle: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 头部
                    HStack(spacing: 16) {
                        Image(systemName: skill.icon)
                            .font(.system(size: 44, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 72, height: 72)
                            .liquidGlass(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(skill.displayName)
                                .font(.title3.weight(.semibold))
                            Text("v\(skill.version) · \(skill.author)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                Image(systemName: skill.category.icon)
                                    .font(.caption2)
                                Text(skill.category.label)
                                    .font(.caption2)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .liquidGlass(.clear, in: Capsule(style: .continuous))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                    // 描述
                    VStack(alignment: .leading, spacing: 8) {
                        Text("描述")
                            .font(.headline)
                        Text(skill.description)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)

                    Divider().opacity(0.2)

                    // System Prompt 预览
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("能力指令预览")
                                .font(.headline)
                            Spacer()
                            Button {
                                UIPasteboard.general.string = skill.systemPrompt
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(skill.systemPrompt)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .liquidGlass(.regular, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 20)

                    Spacer(minLength: 40)
                }
                .padding(.vertical, 16)
            }
            .background(Color(.systemBackground))
            .navigationTitle("Skill 详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isInstalled ? "卸载" : "安装") {
                        onToggle()
                        dismiss()
                    }
                    .foregroundStyle(isInstalled ? Color.red : Color.accentColor)
                    .font(.body.weight(.semibold))
                }
            }
        }
    }
}
