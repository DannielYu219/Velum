//
//  VelumAction.swift
//  Velum
//
//  Phase 1.1: Control Plane action enum.
//  All VM operations flow through this enum so triggers (keyboard / button / MCP)
//  are decoupled from execution (Host Bridge / iSH).
//  Spec: doc&&blueprints/00-overview.md §4.2
//
//  Phase 1 scope: definition + compile only. No iSH wiring.
//

import Foundation

/// Placeholder for Phase 2.3's Swift Data `AppManifest` model.
/// Defined minimally here so `VelumAction.launchApp` compiles today.
public struct AppManifest: Hashable, Identifiable {
    public let id: UUID
    public let name: String
    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// Notification severity level used by `VelumAction.postNotification`.
public enum NotifLevel: Hashable {
    case info
    case warning
    case error
}

/// Every VM-level operation in Velum. New operations get added here — never
/// call iSH / Host Bridge directly from UI, always go through `VelumControl.perform`.
public enum VelumAction: Hashable {

    // MARK: Terminal / TTY

    /// Switch the active terminal to TTY 1..7.
    case switchTTY(Int)
    /// Clear the current terminal screen.
    case clearCurrentScreen
    /// Open terminal settings panel.
    case showTerminalSettings

    // MARK: Desktop / App

    /// Launch the app described by `manifest`.
    case launchApp(AppManifest)
    /// Kill the app whose instance id is `id`.
    case killApp(UUID)
    /// Show the app launcher grid.
    case showLauncher
    /// Show the task switcher.
    case showTaskSwitcher
    /// Minimize the frontmost window.
    case minimizeFrontmost
    /// Open `path` in a Terminal window (e.g. cat the file). Used by Files App.
    case openInTerminal(String)

    // MARK: View / Appearance

    case increaseFont
    case decreaseFont
    case resetFont
    /// Toggle light / dark appearance.
    case toggleAppearance

    // MARK: Host Bridge (Phase 3+ — stubs only for now)

    /// Execute `cmd` with `args`, return full output.
    case execCommand(String, [String])
    /// Execute `cmd` with `args`, stream output line by line.
    case execStream(String, [String])
    /// Read file at `path` from the iSH fakefs.
    case readFile(String)
    /// Write `data` to file at `path` in the iSH fakefs.
    case writeFile(String, Data)
    /// List running processes inside iSH.
    case listProcesses
    /// Mount a host directory into the iSH fakefs.
    case mountHostDir(String, String, readOnly: Bool)

    // MARK: Notifications

    case postNotification(String, level: NotifLevel)
    case listNotifications

    // MARK: System info

    case getUptime
    case getMemUsage
    case getIPAddresses
}
