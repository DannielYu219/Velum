//
//  FilesView.swift
//  Velum
//
//  Phase 3.4: SwiftUI Files App — browse iSH fakefs via ISHBridge.
//
//  Features:
//  - Path bar at top + up-to-parent navigation
//  - List of entries (directories first, then files alphabetically)
//  - Tap directory → navigate in
//  - Long-press file → context menu (open in Terminal / copy path / delete)
//  - Loading + error states
//
//  Data source: ISHBridge.shared.listDir
//

import SwiftUI

struct FilesView: View {
    @State private var path: String
    @State private var entries: [ISHDirEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let bridge = ISHBridge.shared

    init(initialPath: String = "/") {
        _path = State(initialValue: initialPath)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Path bar
            pathBar
            Divider().background(Color.white.opacity(0.1))
            // Content
            content
        }
        .background(Color.clear)
        .task(id: path) {
            await load()
        }
    }

    // MARK: - Path bar

    @ViewBuilder
    private var pathBar: some View {
        HStack(spacing: 8) {
            Button {
                navigateUp()
            } label: {
                Image(systemName: "chevron.up")
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .disabled(path == "/")
            .opacity(path == "/" ? 0.3 : 1.0)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(path)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Loading \(path)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { await load() }
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("Empty directory")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(sortedEntries) { entry in
                    row(for: entry)
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Color.white.opacity(0.1))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
    }

    private var sortedEntries: [ISHDirEntry] {
        entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    @ViewBuilder
    private func row(for entry: ISHDirEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                .imageScale(.large)
                .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(entry.permissionString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(entry.formattedSize)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if entry.isDirectory {
                navigateInto(entry.name)
            }
        }
        .contextMenu {
            Button {
                copyPath(for: entry)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
            if entry.isRegularFile {
                Button {
                    openInTerminal(entry)
                } label: {
                    Label("Open in Terminal", systemImage: "terminal")
                }
            }
            if entry.name != "." && entry.name != ".." {
                Button(role: .destructive) {
                    deleteEntry(entry)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            entries = try await bridge.listDir(path)
        } catch {
            errorMessage = error.localizedDescription
            entries = []
        }
        isLoading = false
    }

    private func navigateInto(_ name: String) {
        path = path == "/" ? "/\(name)" : "\(path)/\(name)"
    }

    private func navigateUp() {
        guard path != "/" else { return }
        let components = path.split(separator: "/")
        if components.isEmpty {
            path = "/"
        } else {
            path = "/" + components.dropLast().joined(separator: "/")
        }
    }

    private func copyPath(for entry: ISHDirEntry) {
        let full = path == "/" ? "/\(entry.name)" : "\(path)/\(entry.name)"
        UIPasteboard.general.string = full
    }

    private func openInTerminal(_ entry: ISHDirEntry) {
        let full = path == "/" ? "/\(entry.name)" : "\(path)/\(entry.name)"
        VelumControl.shared.perform(.openInTerminal(full))
    }

    private func deleteEntry(_ entry: ISHDirEntry) {
        let full = path == "/" ? "/\(entry.name)" : "\(path)/\(entry.name)"
        Task {
            let cmd = entry.isDirectory ? "rm -rf \"\(full)\"" : "rm \"\(full)\""
            _ = try? await bridge.execute(cmd)
            await load()
        }
    }
}

#Preview {
    FilesView()
        .preferredColorScheme(.dark)
}
