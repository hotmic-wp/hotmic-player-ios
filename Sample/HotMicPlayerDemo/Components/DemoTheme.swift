import SwiftUI

/// Small, deliberate visual language for the demo: near-black stage, one hot
/// accent, translucent chrome that never competes with the video.
enum DemoTheme {
    static let accent = Color(red: 0.72, green: 0.38, blue: 1.0)
    static let accentHot = Color(red: 1.0, green: 0.33, blue: 0.55)
    static let live = Color(red: 1.0, green: 0.25, blue: 0.35)

    /// Monospaced digits for anything that ticks, so numbers don't jitter.
    static func metric(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    static func label(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

extension View {
    /// Keeps white text legible over arbitrary video without a full scrim.
    func videoLegible() -> some View {
        shadow(color: .black.opacity(0.55), radius: 6, y: 1)
    }
}

/// Floating chrome button.
///
/// The pill styling lives *inside* the label rather than being applied to the
/// `Button`. Applied outside, the padding sits outside the hit region and you
/// get a ~18pt target that is almost impossible to hit. The 44pt minimum is
/// enforced here so no call site has to remember it.
struct ChromeButton<Label: View>: View {

    var isActive: Bool = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(isActive ? DemoTheme.accent : .white)
                .padding(.horizontal, 12)
                .frame(minWidth: 44, minHeight: 44)
                .background(.ultraThinMaterial, in: .capsule)
                .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 0.5))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

extension ChromeButton where Label == Image {
    init(systemImage: String, isActive: Bool = false, action: @escaping () -> Void) {
        self.init(isActive: isActive, action: action) {
            Image(systemName: systemImage)
        }
    }
}
