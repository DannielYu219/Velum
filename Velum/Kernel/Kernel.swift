//
//  Kernel.swift
//  Velum
//
//  Swift facade over the iSH kernel lifecycle.
//
//  The real boot still happens synchronously inside AppDelegate.application(_:willFinishLaunchingWithOptions:)
//  (iSH requires this — task_start must run before the run loop pumps).
//  This singleton is a *read-only observer* for the rest of the SwiftUI layer:
//  it reflects the state that AppDelegate reports via KernelObjCBridge.
//
//  Phase 0.2 scope: observation only. A future phase may add an async boot()
//  entry point that actually drives the C symbols; for now we stay hands-off
//  so we never race the AppDelegate boot path.
//

import Foundation
import Combine

@MainActor
public final class Kernel: ObservableObject {

    public static let shared = Kernel()

    public enum State: Equatable {
        case unbooted
        case booting
        case ready
        case failed(String)
    }

    @Published public private(set) var state: State = .unbooted

    /// True once AppDelegate has reported a successful boot.
    public var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    private var pollTimer: Timer?

    private init() {
        // No-op construction. The poll loop is started by `startObserving()`,
        // which the SwiftUI app calls once the scene is up.
    }

    /// Begin mirroring the Obj-C bridge state into the Swift @Published state.
    /// Idempotent.
    public func startObserving() {
        if pollTimer != nil { return }
        // Initial sync read so the very first render is correct.
        mirrorBridgeState()
        // Then poll every 0.25s — cheap, and avoids needing a GCD channel.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.mirrorBridgeState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Stop observing. Called on scene disconnect if needed.
    public func stopObserving() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Mirror the Obj-C bridge state into the Swift enum.
    private func mirrorBridgeState() {
        let bridge = KernelObjCBridge.sharedInstance()
        switch bridge.currentState {
        case .unbooted: state = .unbooted
        case .booting:  state = .booting
        case .ready:    state = .ready
        case .failed:
            let msg = bridge.bootError?.localizedDescription ?? "unknown iSH boot error"
            state = .failed(msg)
        @unknown default: state = .unbooted
        }
    }
}
