//
//  SessionSidebarView.swift
//  Velum
//
//  照抄 Visor SidebarView：会话列表面板
//  适配 Velum：SessionStore actor + AgentSession（JSONL 持久化）
//

import SwiftUI

struct SessionSidebarView: View {
    @Binding var selectedSessionId: String?
    @Binding var isCollapsed: Bool
    @State private var sessions: [AgentSession] = []
    @State private var newSessionTitle: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.2)
            sessionList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial.opacity(0.6))
        .task {
            await reload()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            if !isCollapsed {
                Text("会话")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.leading, 12)
            }
            Spacer()
            Button {
                Task { await createNew() }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
        }
        .padding(.vertical, 10)
    }

    // MARK: - Session List

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if sessions.isEmpty {
                    Text("暂无会话")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 20)
                } else {
                    ForEach(sessions) { session in
                        sessionRow(session)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: AgentSession) -> some View {
        let isSelected = session.id == selectedSessionId
        Button {
            selectedSessionId = session.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "bubble.left.fill" : "bubble.left")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(session.updatedAt.formatted(.relative(presentation: .numeric)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : .clear)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                Task { await delete(session) }
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    // MARK: - Actions

    private func reload() async {
        sessions = await SessionStore.shared.listSessions()
    }

    private func createNew() async {
        let session = await SessionStore.shared.createSession()
        selectedSessionId = session.id
        await reload()
    }

    private func delete(_ session: AgentSession) async {
        await SessionStore.shared.deleteSession(id: session.id)
        if selectedSessionId == session.id {
            let remaining = await SessionStore.shared.listSessions()
            selectedSessionId = remaining.first?.id
        }
        await reload()
    }
}
