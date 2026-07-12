//
//  GlassCompat.swift
//  Velum
//
//  Phase 2.0: Liquid Glass compatibility layer.
//
//  Strategy:
//  - iOS 26+: use native `.glassEffect()` (true Liquid Glass)
//  - iOS < 26: fall back to `.ultraThinMaterial` / `.regularMaterial` blur
//
//  All glass surfaces take an explicit `Shape` so corner radii stay aligned
//  across the hierarchy (R-angle centers coincide).
//
//  Reference prototype: ~/Downloads/Velum Desktop UI.rtf
//

import SwiftUI

// MARK: - Glass Style

/// Mirrors the prototype's `.glassEffect(.regular)` / `.glassEffect(.clear.tint(...))` variants.
public enum GlassStyle {
    /// Default frosted glass — maps to `.glassEffect(.regular)` / `.regularMaterial`.
    case regular
    /// Clear glass with optional tint — maps to `.glassEffect(.clear.tint(...))` / `.ultraThinMaterial` + tint.
    case clear
}

// MARK: - Glass Modifier

public extension View {
    /// Apply Liquid Glass (iOS 26+) or a blur fallback (iOS < 26) clipped to `shape`.
    /// All callers pass the same shape family (`.continuous` capsules / rects) so
    /// corner-radius centers stay aligned across the view tree.
    func liquidGlass(
        _ style: GlassStyle = .regular,
        tint: Color? = nil,
        in shape: some Shape
    ) -> some View {
        modifier(GlassModifier(style: style, tint: tint, shape: shape))
    }
}

private struct GlassModifier<S: Shape>: ViewModifier {
    let style: GlassStyle
    let tint: Color?
    let shape: S

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            nativeGlass(content)
        } else {
            fallbackGlass(content)
        }
    }

    // iOS 26+: native Liquid Glass
    @available(iOS 26.0, *)
    private func nativeGlass(_ content: Content) -> some View {
        content
            .background {
                shape
                    .hidden()
                    .glassEffect(nativeStyle, in: shape)
            }
    }

    @available(iOS 26.0, *)
    private var nativeStyle: Glass {
        switch style {
        case .regular:
            return tint.map { Glass.regular.tint($0) } ?? Glass.regular
        case .clear:
            return tint.map { Glass.clear.tint($0) } ?? Glass.clear
        }
    }

    // iOS < 26: blur fallback
    private func fallbackGlass(_ content: Content) -> some View {
        content
            .background {
                shape
                    .fill(material)
                    .overlay {
                        if let tint {
                            shape.fill(tint.opacity(0.18))
                        }
                    }
            }
    }

    private var material: Material {
        switch style {
        case .regular: return .regularMaterial
        case .clear:   return .ultraThinMaterial
        }
    }
}

// MARK: - GlassSurface (standalone glass layer)

/// A standalone glass surface clipped to `shape`.
///
/// Use as the bottom layer of a `ZStack`, exactly mirroring the prototype's
/// `Circle().hidden().glassEffect(.regular, in: .circle)` pattern.
///
/// For `interactive: true` (dock capsule), the shape is NOT hidden — instead it
/// gets a near-transparent `.foregroundStyle(.white.opacity(0.01))` so it can
/// receive touches (per prototype comment: "needed for interactive").
public struct GlassSurface<S: Shape>: View {
    public let style: GlassStyle
    public let tint: Color?
    public let interactive: Bool
    public let shape: S

    public init(_ style: GlassStyle = .regular,
                tint: Color? = nil,
                interactive: Bool = false,
                in shape: S) {
        self.style = style
        self.tint = tint
        self.interactive = interactive
        self.shape = shape
    }

    public var body: some View {
        if #available(iOS 26.0, *) {
            nativeSurface
        } else {
            fallbackSurface
        }
    }

    // iOS 26+: native Liquid Glass — mirror prototype exactly
    @available(iOS 26.0, *)
    @ViewBuilder
    private var nativeSurface: some View {
        if interactive {
            // Interactive glass needs a (near-)opaque foregroundStyle to receive
            // touches. Prototype: .foregroundStyle(.white.opacity(0.01))
            shape
                .foregroundStyle(.white.opacity(0.01))
                .glassEffect(nativeGlass, in: shape)
        } else {
            // Non-interactive: shape is hidden, glassEffect still renders.
            shape
                .hidden()
                .glassEffect(nativeGlass, in: shape)
        }
    }

    @available(iOS 26.0, *)
    private var nativeGlass: Glass {
        let base: Glass
        switch style {
        case .regular: base = Glass.regular
        case .clear:   base = Glass.clear
        }
        let tinted = tint.map { base.tint($0) } ?? base
        return interactive ? tinted.interactive() : tinted
    }

    // iOS < 26: blur fallback
    @ViewBuilder
    private var fallbackSurface: some View {
        shape
            .fill(material)
            .overlay {
                if let tint {
                    shape.fill(tint.opacity(0.18))
                }
            }
    }

    private var material: Material {
        switch style {
        case .regular: return .regularMaterial
        case .clear:   return .ultraThinMaterial
        }
    }
}

// MARK: - Interactive Glass Modifier (for dock) — legacy, prefer GlassSurface

public extension View {
    /// Interactive variant — iOS 26+ gets `.interactive()`, fallback stays static.
    func interactiveLiquidGlass(
        tint: Color? = nil,
        in shape: some Shape
    ) -> some View {
        modifier(InteractiveGlassModifier(tint: tint, shape: shape))
    }
}

private struct InteractiveGlassModifier<S: Shape>: ViewModifier {
    let tint: Color?
    let shape: S

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .background {
                    shape
                        .hidden()
                        .glassEffect(Glass.clear.tint(tint ?? .clear.opacity(0.06)).interactive(), in: shape)
                }
        } else {
            content
                .background {
                    shape
                        .fill(.ultraThinMaterial)
                        .overlay {
                            if let tint {
                                shape.fill(tint.opacity(0.18))
                            } else {
                                shape.fill(Color.white.opacity(0.06))
                            }
                        }
                }
        }
    }
}
