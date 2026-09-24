import SwiftUI

// The app's motion system. One spring family, short staggers, and nothing that moves
// for its own sake: motion shows where a view came from, what changed, or that a tap
// landed. Every effect here checks Reduce Motion and falls back to a plain fade or to
// no animation at all.

enum Motion {
    /// Cards, rings, and page elements settling into place.
    static let settle = Animation.spring(response: 0.55, dampingFraction: 0.84)
    /// Quick state changes: a number rolling, a status line swapping.
    static let snappy = Animation.snappy(duration: 0.32)
    /// Ring and bar fills: slower, so the eye can follow the value.
    static let fill = Animation.spring(response: 1.05, dampingFraction: 0.86)
    /// Press feedback on tappable cards.
    static let press = Animation.spring(response: 0.28, dampingFraction: 0.68)

    /// Delay for the `index`th element of a staggered group. Capped so a long page
    /// never makes the user wait for the bottom.
    static func stagger(_ index: Int, step: Double = 0.055) -> Double {
        Double(min(index, 7)) * step
    }
}

// ── entrance ─────────────────────────────────────────────────────────────────
/// Fades and lifts a view into place the first time it appears, staggered by index.
/// Runs once per view lifetime, so returning from a detail page does not replay it.
private struct Entrance: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 22)
            .scaleEffect(shown || reduceMotion ? 1 : 0.97, anchor: .top)
            .onAppear {
                guard !shown else { return }
                let animation = reduceMotion
                    ? Animation.easeOut(duration: 0.2)
                    : Motion.settle.delay(Motion.stagger(index))
                withAnimation(animation) { shown = true }
            }
    }
}

// ── scroll-in ────────────────────────────────────────────────────────────────
/// Cards rising from the bottom edge scale up and fade in as they scroll into view,
/// the way the App Store's Today cards do. Cards leaving at the top stay still, so
/// the large title and the chrome never feel busy.
private struct ScrollIn: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.scrollTransition(topLeading: .identity, bottomTrailing: .interactive) { view, phase in
                view
                    .opacity(phase.isIdentity ? 1 : 0.75)
                    .scaleEffect(phase.isIdentity ? 1 : 0.965, anchor: .top)
                    .offset(y: phase.isIdentity ? 0 : 10)
            }
        }
    }
}

// ── draw-in reveal ───────────────────────────────────────────────────────────
/// Wipes a chart in from the leading edge on first appearance, so a trend line reads
/// as time passing rather than popping in whole.
private struct Reveal: ViewModifier {
    var delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .mask(alignment: .leading) {
                // taller than the view, so axis labels that overhang the plot
                // (a "100" on the top gridline) are never clipped
                GeometryReader { geo in
                    Rectangle()
                        .frame(width: geo.size.width * progress + 1, height: geo.size.height + 48)
                        .offset(y: -24)
                }
            }
            .onAppear {
                guard progress == 0 else { return }
                if reduceMotion {
                    progress = 1
                } else {
                    withAnimation(.easeInOut(duration: 0.9).delay(delay)) { progress = 1 }
                }
            }
    }
}

// ── press feedback ───────────────────────────────────────────────────────────
/// Tappable cards dip slightly under the finger and spring back on release.
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.965 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

// ── rolling numbers ──────────────────────────────────────────────────────────
/// A number that counts through the values between its old and new state. SwiftUI
/// interpolates `animatableData`, so a ring filling to 87 shows 0…87 on the way.
struct CountingNumber: ViewModifier, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    func body(content: Content) -> some View {
        Text("\(Int(value.rounded()))")
    }
}

// ── zoom navigation (iOS 18+) ────────────────────────────────────────────────
/// The namespace a card uses as the source of a zoom transition into its detail.
private struct ZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var zoomNamespace: Namespace.ID? {
        get { self[ZoomNamespaceKey.self] }
        set { self[ZoomNamespaceKey.self] = newValue }
    }
}

private struct ZoomSource<ID: Hashable>: ViewModifier {
    let id: ID
    @Environment(\.zoomNamespace) private var namespace
    func body(content: Content) -> some View {
        if #available(iOS 18, *), let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

// ── shimmer ──────────────────────────────────────────────────────────────────
/// A soft band of light that sweeps across placeholders while content loads.
private struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1
    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, Color.primary.opacity(0.07), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.6)
                            .offset(x: phase * geo.size.width * 1.6)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

extension View {
    /// Sweep a soft shimmer across this view (skipped under Reduce Motion).
    func shimmer() -> some View { modifier(Shimmer()) }
    /// Fade and lift into place on first appearance, `index` steps into a stagger.
    func entrance(_ index: Int = 0) -> some View { modifier(Entrance(index: index)) }
    /// Scale and fade in when scrolling up from the bottom edge.
    func scrollIn() -> some View { modifier(ScrollIn()) }
    /// Wipe in from the leading edge on first appearance.
    func reveal(delay: Double = 0) -> some View { modifier(Reveal(delay: delay)) }
    /// Mark this view as the origin of a zoom transition to the destination with `id`.
    func zoomSource(_ id: some Hashable) -> some View { modifier(ZoomSource(id: id)) }

    /// On iOS 18+, push this destination with a zoom out of the view marked
    /// `zoomSource(id)`. Earlier systems keep the standard push.
    @ViewBuilder
    func zoomDestination(_ id: some Hashable, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18, *) {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}
