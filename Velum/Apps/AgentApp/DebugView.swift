//
//  DebugView.swift
//  Velum
//
//  照抄 Visor DebugView + DebugBadgeButton
//  Debug 面板：三标签（终端 / Token / 错误）+ 过滤 + 清空 + 复制
//

import SwiftUI

/// Debug 面板：三标签（终端 / Token / 错误）
struct DebugView: View {
    @ObservedObject private var bus = DebugBus.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: Tab = .terminal
    @State private var filter: String = ""

    enum Tab: String, CaseIterable, Identifiable {
        case terminal
        case token
        case error
        var id: String { rawValue }
        var label: String {
            switch self {
            case .terminal: return "终端"
            case .token: return "Token"
            case .error: return "错误"
            }
        }
        var icon: String {
            switch self {
            case .terminal: return "terminal"
            case .token: return "dollarsign.circle"
            case .error: return "exclamationmark.triangle"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    ForEach(Tab.allCases) { tab in
                        Label(tab.label, systemImage: tab.icon).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider().opacity(0.2)

                eventList
            }
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("清空", role: .destructive) {
                            DebugBus.shared.clear()
                        }
                        Button("复制全部") {
                            let dump = bus.events.map(serialize).joined(separator: "\n")
                            UIPasteboard.general.string = dump
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var eventList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if filteredEvents.isEmpty {
                        emptyState
                    } else {
                        ForEach(filteredEvents) { event in
                            eventRow(event)
                                .id(event.id)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: bus.events.last?.id) { lastId in
                if let lastId {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: selectedTab.icon)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(selectedTab == .terminal
                 ? "暂无终端日志"
                 : selectedTab == .token
                 ? "暂无 Token 记录"
                 : "暂无错误")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    @ViewBuilder
    private func eventRow(_ event: DebugEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: event.iconName)
                    .font(.system(size: 11))
                    .foregroundStyle(event.levelColor)
                Text(event.title)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                Spacer()
                Text(event.timestamp.formatted(.dateTime.hour().minute().second()))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if !event.detail.isEmpty {
                Text(event.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(event.level == .error
                    ? Color.red.opacity(0.06)
                    : Color.clear)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.15)
        }
    }

    // MARK: - Filtering

    private var filteredEvents: [DebugEvent] {
        let kind: DebugEvent.Kind
        switch selectedTab {
        case .terminal: kind = .cli
        case .token: kind = .token
        case .error: kind = .error
        }
        return bus.events
            .filter { $0.kind == kind || (selectedTab == .terminal && $0.kind == .tool) }
            .filter { event in
                filter.isEmpty
                || event.title.localizedCaseInsensitiveContains(filter)
                || event.detail.localizedCaseInsensitiveContains(filter)
            }
            .suffix(500)
    }

    private func serialize(_ event: DebugEvent) -> String {
        let fmt = ISO8601DateFormatter()
        return "[\(fmt.string(from: event.timestamp))] [\(event.kind.rawValue)] [\(event.level.rawValue)] \(event.title)\n\(event.detail)"
    }
}

/// Debug 按钮 + 事件计数 badge
struct DebugBadgeButton: View {
    @Binding var showDebug: Bool
    @ObservedObject private var bus = DebugBus.shared
    @State private var lastSeenCount: Int = 0
    @State private var hasUnreadError: Bool = false

    var body: some View {
        Button {
            showDebug = true
            lastSeenCount = bus.events.count
            hasUnreadError = false
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "ladybug")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 48, height: 48)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))

                if hasUnreadError {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .offset(x: 5, y: -3)
                } else if hasNewEvents {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 8, height: 8)
                        .offset(x: 5, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Debug")
        .onChange(of: bus.events.count) { _ in
            updateBadge()
        }
        .onAppear {
            lastSeenCount = bus.events.count
            hasUnreadError = false
        }
    }

    private var hasNewEvents: Bool {
        bus.events.count > lastSeenCount
    }

    private func updateBadge() {
        if let last = bus.events.last, last.kind == .error, last.level == .error {
            hasUnreadError = true
        }
    }
}
