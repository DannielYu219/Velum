//
//  TopBar.swift
//  Velum
//
//  Phase 2.1: Desktop top bar.
//  Shows app title (Velum) + live clock + iSH Kernel state.
//  Glass surface uses Liquid Glass on iOS 26+, blur fallback below.
//

import SwiftUI

struct TopBar: View {
    @ObservedObject private var kernel = Kernel.shared
    @State private var now = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 16) {
            // Left: app title
            HStack(spacing: 8) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.headline)
                    .foregroundStyle(.tint)
                Text("Velum")
                    .font(.headline.bold())
            }

            Spacer()

            // Center: clock
            Text(now, format: .dateTime.hour().minute())
                .font(.headline.monospacedDigit())
                .monospacedDigit()
                .onReceive(timer) { now = $0 }

            Spacer()

            // Right: kernel state
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(kernelStateText)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        // Pill-shaped glass bar — capsule ensures both ends share the same
        // corner-radius center, matching the dock below.
        .liquidGlass(.clear, tint: .clear.opacity(0.06), in: Capsule(style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var kernelStateText: String {
        switch kernel.state {
        case .unbooted:       return "unbooted"
        case .booting:        return "booting\u{2026}"
        case .ready:          return "ready"
        case .failed(let m):  return "failed \u{2014} \(m)"
        }
    }

    private var statusColor: Color {
        switch kernel.state {
        case .unbooted: return .gray
        case .booting:  return .orange
        case .ready:    return .green
        case .failed:   return .red
        }
    }
}

#Preview {
    TopBar()
        .background(Color.black.opacity(0.4))
}
