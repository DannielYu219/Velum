//
//  TopBar.swift
//  Velum
//
//  Minimal time display in the top-right corner.
//

import SwiftUI

struct TopBar: View {
    @State private var now = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(now, format: .dateTime.hour().minute())
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: 64, height: 28)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.45))
            )
            .onReceive(timer) { now = $0 }
    }
}

#Preview {
    TopBar()
        .background(Color.black.opacity(0.4))
}
