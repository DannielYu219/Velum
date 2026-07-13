//
//  AgentSettingsView.swift
//  Velum
//
//  照抄 Visor SettingsView + CustomProviderEditorSheet
//  集成：OpenRouter 模型目录选择 + 自定义服务商管理 + 系统指令
//

import SwiftUI

struct AgentSettingsView: View {
    @ObservedObject private var config = AgentConfig.shared
    @State private var apiKeyInput: String = ""
    @State private var showAPIKey: Bool = false
    @State private var keySaved: Bool = false
    @State private var customProviders: [CustomProviderConfig] = []
    @State private var editingTarget: ProviderEditTarget?
    @State private var showModelPicker: Bool = false
    @Environment(\.dismiss) private var dismiss

    // Sheet 编辑目标
    private struct ProviderEditTarget: Identifiable {
        let id = UUID()
        let config: CustomProviderConfig?  // nil = 新增
    }

    var body: some View {
        NavigationStack {
            List {
                modelSection
                openRouterKeySection
                systemPromptSection
                customProviderSection
                dangerSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .navigationTitle("Agent 设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                loadAPIKey()
                reloadCustomProviders()
            }
            .sheet(item: $editingTarget, onDismiss: { reloadCustomProviders() }) { target in
                CustomProviderEditorSheet(
                    editing: target.config,
                    onSave: { cfg, apiKey in
                        saveCustomProvider(cfg, apiKey: apiKey)
                    }
                )
            }
        }
    }

    // MARK: - 模型选择

    private var modelSection: some View {
        Section {
            Button {
                showModelPicker = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("当前模型")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(config.modelDisplayName)
                            .font(.body)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("模型")
        } footer: {
            Text("从 OpenRouter 目录选择，或添加自定义服务商。")
                .font(.caption)
        }
        .listRowBackground(Color.clear)
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(selectedModelId: $config.model)
        }
    }

    // MARK: - OpenRouter API Key

    private var openRouterKeySection: some View {
        Section {
            HStack {
                if showAPIKey {
                    TextField("sk-or-...", text: $apiKeyInput)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.body.monospaced())
                } else {
                    SecureField("sk-or-...", text: $apiKeyInput)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.body.monospaced())
                }
                Button {
                    showAPIKey.toggle()
                } label: {
                    Image(systemName: showAPIKey ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                saveAPIKey()
            } label: {
                HStack {
                    Label("保存 API Key", systemImage: "lock.fill")
                    Spacer()
                    if keySaved {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }

            Button(role: .destructive) {
                deleteAPIKey()
            } label: {
                Label("删除 API Key", systemImage: "trash")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Endpoint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("https://openrouter.ai/api/v1", text: $config.endpoint)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.body.monospaced())
            }
        } header: {
            Text("OpenRouter 配置")
        } footer: {
            Text("使用 OpenRouter 目录中的模型时需要此 Key。存储在 Keychain，不会同步到 iCloud。")
                .font(.caption)
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - System Prompt

    private var systemPromptSection: some View {
        Section {
            TextEditor(text: $config.systemPrompt)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .frame(minHeight: 60, maxHeight: 160)
        } header: {
            Text("自定义系统指令")
        } footer: {
            Text("追加到默认 system prompt 之后。留空则不追加。")
                .font(.caption)
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - 自定义服务商

    private var customProviderSection: some View {
        Section {
            if customProviders.isEmpty {
                Text("暂无自定义服务商")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(customProviders) { cfg in
                    customProviderRow(cfg)
                }
            }
            Button {
                editingTarget = ProviderEditTarget(config: nil)
            } label: {
                Label("添加自定义服务商", systemImage: "plus")
            }
        } header: {
            Text("自定义服务商")
        } footer: {
            Text("OpenAI 兼容协议。每个服务商可配置多个模型，API Key 独立存储在 Keychain。")
                .font(.caption)
        }
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private func customProviderRow(_ cfg: CustomProviderConfig) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(cfg.name)
                    .font(.body)
                Text(cfg.baseURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(cfg.models.count) 个模型")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                editingTarget = ProviderEditTarget(config: cfg)
            } label: {
                Image(systemName: "square.and.pencil")
            }
            Button(role: .destructive) {
                deleteCustomProvider(cfg)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Danger

    private var dangerSection: some View {
        Section("危险操作") {
            Button(role: .destructive) {
                Task { await SessionStore.shared.deleteAllSessions() }
            } label: {
                Label("清空所有会话历史", systemImage: "trash")
            }
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Actions

    private func loadAPIKey() {
        apiKeyInput = config.apiKey
        keySaved = false
    }

    private func saveAPIKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        config.apiKey = key
        withAnimation { keySaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { keySaved = false }
        }
    }

    private func deleteAPIKey() {
        config.apiKey = ""
        apiKeyInput = ""
        keySaved = false
    }

    private func reloadCustomProviders() {
        CustomProviderRegistry.shared.reload()
        customProviders = CustomProviderRegistry.shared.allConfigs()
    }

    private func saveCustomProvider(_ cfg: CustomProviderConfig, apiKey: String) {
        var current = CustomProviderRegistry.shared.allConfigs()
        if let idx = current.firstIndex(where: { $0.id == cfg.id }) {
            current[idx] = cfg
        } else {
            current.append(cfg)
        }
        CustomProviderRegistry.shared.save(current)
        if !apiKey.isEmpty {
            try? CustomProviderRegistry.shared.setAPIKey(apiKey, for: cfg.id)
        }
        reloadCustomProviders()
    }

    private func deleteCustomProvider(_ cfg: CustomProviderConfig) {
        var current = CustomProviderRegistry.shared.allConfigs()
        current.removeAll { $0.id == cfg.id }
        CustomProviderRegistry.shared.save(current)
        CustomProviderRegistry.shared.deleteAPIKey(for: cfg.id)
        // 如果当前选中的是这个 provider 的模型，切回默认
        if config.model.hasPrefix("custom::\(cfg.id.uuidString)::") {
            config.model = ModelCatalog.defaultModelId
        }
        reloadCustomProviders()
    }
}

// MARK: - 模型选择 Sheet

private struct ModelPickerSheet: View {
    @Binding var selectedModelId: String
    @Environment(\.dismiss) private var dismiss
    @State private var customProviders: [CustomProviderConfig] = []

    var body: some View {
        NavigationStack {
            List {
                Section("OpenRouter 目录") {
                    ForEach(ModelCatalog.catalog) { info in
                        Button {
                            selectedModelId = info.id
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(info.displayName)
                                        .foregroundStyle(.primary)
                                    Text(info.id)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedModelId == info.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                }

                if !customProviders.isEmpty {
                    Section("自定义服务商") {
                        ForEach(customProviders) { cfg in
                            ForEach(cfg.models) { model in
                                Button {
                                    selectedModelId = cfg.namespacedModelId(model.id)
                                    dismiss()
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("\(cfg.name) · \(model.displayName)")
                                                .foregroundStyle(.primary)
                                            Text(model.id)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if selectedModelId == cfg.namespacedModelId(model.id) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.accentColor)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("选择模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                CustomProviderRegistry.shared.reload()
                customProviders = CustomProviderRegistry.shared.allConfigs()
            }
        }
    }
}

// MARK: - 自定义服务商编辑 Sheet（照抄 Visor CustomProviderEditorSheet）

struct CustomProviderEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let editing: CustomProviderConfig?
    let onSave: (CustomProviderConfig, String) -> Void

    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var showAPIKey: Bool = false
    @State private var models: [EditableModel] = []
    @State private var errorMessage: String?
    @State private var hasExistingKey: Bool = false
    @State private var isTesting: Bool = false
    @State private var testResult: TestResult?

    enum TestResult {
        case success(modelCount: Int)
        case failure(String)
    }

    struct EditableModel: Identifiable {
        let id = UUID()
        var modelId: String = ""
        var displayName: String = ""
    }

    private var isNew: Bool { editing == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("基础信息") {
                    TextField("名称（如：我的 OpenAI）", text: $name)
                        .autocorrectionDisabled()
                    TextField("Base URL（https://api.openai.com/v1）", text: $baseURL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }

                Section("API Key") {
                    HStack {
                        if showAPIKey {
                            TextField("sk-...", text: $apiKey)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        } else {
                            SecureField("sk-...", text: $apiKey)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                        Button {
                            showAPIKey.toggle()
                        } label: {
                            Image(systemName: showAPIKey ? "eye.slash" : "eye")
                        }
                    }
                    if hasExistingKey && apiKey.isEmpty {
                        Text("已配置 Key（不修改则保持不变）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        testConnectivity()
                    } label: {
                        HStack(spacing: 4) {
                            if isTesting {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                            }
                            Text(isTesting ? "测试中..." : "测试连通性")
                        }
                    }
                    .disabled(isTesting)

                    if let result = testResult {
                        switch result {
                        case .success(let count):
                            Text("连接成功（\(count) 个模型）")
                                .font(.caption)
                                .foregroundStyle(.green)
                        case .failure(let msg):
                            Text("失败：\(msg)")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }

                Section("模型列表") {
                    ForEach($models) { $model in
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("模型 ID（如 gpt-4o）", text: $model.modelId)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            TextField("显示名（如 GPT-4o）", text: $model.displayName)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                    }
                    .onDelete { offsets in
                        models.remove(atOffsets: offsets)
                    }
                    Button {
                        models.append(EditableModel())
                    } label: {
                        Label("添加模型", systemImage: "plus")
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(isNew ? "新增服务商" : "编辑服务商")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .onAppear { loadEditing() }
        }
    }

    // MARK: - 逻辑

    private func loadEditing() {
        guard let editing else { return }
        name = editing.name
        baseURL = editing.baseURL
        models = editing.models.map { EditableModel(modelId: $0.id, displayName: $0.displayName) }
        hasExistingKey = CustomProviderRegistry.shared.apiKey(for: editing.id) != nil
    }

    private func testConnectivity() {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, let base = URL(string: trimmedURL) else {
            testResult = .failure("Base URL 无效")
            return
        }

        let key: String
        if !apiKey.isEmpty {
            key = apiKey
        } else if let existing = editing.flatMap({ CustomProviderRegistry.shared.apiKey(for: $0.id) }) {
            key = existing
        } else {
            testResult = .failure("缺少 API Key")
            return
        }

        isTesting = true
        testResult = nil

        let url = base.appendingPathComponent("models")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10

        Task {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                await MainActor.run {
                    isTesting = false
                    guard let http = resp as? HTTPURLResponse else {
                        testResult = .failure("响应无效")
                        return
                    }
                    if http.statusCode == 200 {
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let list = json["data"] as? [[String: Any]] {
                            testResult = .success(modelCount: list.count)
                        } else {
                            testResult = .success(modelCount: 0)
                        }
                    } else if http.statusCode == 401 || http.statusCode == 403 {
                        testResult = .failure("API Key 无效（\(http.statusCode)）")
                    } else {
                        let body = String(data: data, encoding: .utf8) ?? ""
                        testResult = .failure("HTTP \(http.statusCode): \(String(body.prefix(80)))")
                    }
                }
            } catch {
                await MainActor.run {
                    isTesting = false
                    testResult = .failure(error.localizedDescription)
                }
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "名称不能为空"
            return
        }
        guard !trimmedURL.isEmpty, URL(string: trimmedURL) != nil else {
            errorMessage = "Base URL 无效"
            return
        }
        let validModels = models.compactMap { m -> CustomModelInfo? in
            let mid = m.modelId.trimmingCharacters(in: .whitespacesAndNewlines)
            let dname = m.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !mid.isEmpty, !dname.isEmpty else { return nil }
            if mid.lowercased().hasPrefix("http://") || mid.lowercased().hasPrefix("https://") {
                errorMessage = "模型 ID 不应为 URL：\(mid)"
                return nil
            }
            return CustomModelInfo(id: mid, displayName: dname, supportsVision: false)
        }
        guard !validModels.isEmpty, errorMessage == nil else {
            if errorMessage == nil { errorMessage = "至少需要一个有效模型" }
            return
        }

        let id = editing?.id ?? UUID()
        let cfg = CustomProviderConfig(
            id: id,
            name: trimmedName,
            baseURL: trimmedURL,
            models: validModels,
            createdAt: editing?.createdAt ?? Date()
        )
        onSave(cfg, apiKey)
        dismiss()
    }
}
