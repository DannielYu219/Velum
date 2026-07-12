//
//  VelumControl.swift
//  Velum
//
//  Phase 1.2: Control Plane singleton.
//  Phase 1 scope: `perform` only logs — no iSH wiring yet.
//  Host Bridge (Phase 3) will subscribe to the action stream and execute.
//
//  Spec: doc&&blueprints/00-overview.md §4.2
//

import Foundation

@MainActor
public final class VelumControl: ObservableObject {

    public static let shared = VelumControl()

    /// Last action performed — SwiftUI views can `@Published` observe for diagnostics.
    @Published public private(set) var lastAction: VelumAction?

    /// Thread-safe store of observer continuations. Lives outside actor isolation
    /// because `AsyncStream.Continuation` is `Sendable` and `yield` is thread-safe,
    /// but `onTermination` runs in a non-main context.
    private let store = ContinuationStore<VelumAction>()

    private init() {}

    /// Perform an action. Phase 1: log only. Phase 3+: routes to Host Bridge.
    public func perform(_ action: VelumAction) {
        lastAction = action
        print("[VelumControl] \(action)")
        store.forEach { $0.yield(action) }
    }

    /// Observe every action flowing through the control plane.
    public func observe() -> AsyncStream<VelumAction> {
        AsyncStream { continuation in
            let id = store.insert(continuation)
            continuation.onTermination = { [store] _ in
                store.remove(id)
            }
        }
    }
}

/// Lock-protected continuation store, safe to share across actors.
private final class ContinuationStore<T: Sendable>: @unchecked Sendable {
    private var storage: [UUID: AsyncStream<T>.Continuation] = [:]
    private let lock = NSLock()

    @discardableResult
    func insert(_ c: AsyncStream<T>.Continuation) -> UUID {
        let id = UUID()
        lock.lock(); defer { lock.unlock() }
        storage[id] = c
        return id
    }

    func remove(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: id)
    }

    func forEach(_ body: (AsyncStream<T>.Continuation) -> Void) {
        lock.lock(); defer { lock.unlock() }
        for c in storage.values { body(c) }
    }
}
