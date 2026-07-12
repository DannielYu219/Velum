//
//  TerminalView.swift
//  Velum
//
//  Phase 0.4: SwiftUI wrapper around the Obj-C TerminalViewController,
//  so the desktop can present the terminal on demand.
//
//  TerminalViewController relies on IBOutlets wired in Terminal.storyboard,
//  so it MUST be instantiated from the storyboard — not via alloc/init.
//

import SwiftUI
import UIKit

struct TerminalView: UIViewControllerRepresentable {

    func makeUIViewController(context: Context) -> TerminalViewController {
        let storyboard = UIStoryboard(name: "Terminal", bundle: .main)
        guard let vc = storyboard.instantiateInitialViewController() as? TerminalViewController else {
            fatalError("Terminal.storyboard's initial view controller is not a TerminalViewController")
        }
        // Velum runs on iPad with an external keyboard (Magic Keyboard / USB).
        // Force-set hasExternalKeyboard so the extra-keys bar (esc/tab/ctrl/...)
        // is hidden from the very first frame — no flash.
        vc.hasExternalKeyboard = true
        vc.startNewSession()
        currentTerminalViewController = vc
        return vc
    }

    func updateUIViewController(_ uiViewController: TerminalViewController, context: Context) {
        // Keep the extra-keys bar suppressed across re-renders.
        uiViewController.hasExternalKeyboard = true
    }
}
