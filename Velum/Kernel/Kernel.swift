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

    /// Token for the boot-state-change notification observer (replaces the old poll timer).
    private var stateObserver: NSObjectProtocol?

    private init() {
        // No-op construction. Observation is started by `startObserving()`,
        // which the SwiftUI app calls once the scene is up.
    }

    /// Begin mirroring the Obj-C bridge state into the Swift @Published state.
    ///
    /// The entire iSH boot runs synchronously inside `AppDelegate willFinishLaunching`
    /// — i.e. *before* the scene (and this observer) exists — so a single initial read
    /// captures the terminal state. The notification observer only covers later
    /// transitions (e.g. a future `restart()`), replacing the previous 0.25s poll timer.
    /// Idempotent.
    public func startObserving() {
        if stateObserver != nil { return }
        // Initial sync read so the very first render is correct.
        mirrorBridgeState()
        stateObserver = NotificationCenter.default.addObserver(
            forName: .VLMKernelStateDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.mirrorBridgeState() }
        }
    }

    /// Stop observing. Called on scene disconnect if needed.
    public func stopObserving() {
        if let stateObserver {
            NotificationCenter.default.removeObserver(stateObserver)
        }
        stateObserver = nil
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
