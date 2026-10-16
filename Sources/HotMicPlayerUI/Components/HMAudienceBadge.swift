#if os(iOS)
import SwiftUI
import HotMicPlayer

/// "1.2K watching" for a live audience, or "1.2K views" for recorded media. Nil counts hide it, and the
/// audience count wins when both are present. Changes roll the digits, or switch in place under Reduce
/// Motion. The source owns refresh and pushes the latest value; the badge never polls.
public struct HMAudienceBadge: View {
    /// People watching now; nil hides the live form.
    public var audienceCount: Int?
    /// Total views for recorded media, shown only without an audience count.
    public var viewCount: Int?
    @Environment(\.hmTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    struct Label: Equatable {
        enum Unit: Equatable {
            case watching
            case views
        }
        var compact: String
        var exact: String
        var unit: Unit
    }
    static func label(audienceCount: Int?, viewCount: Int?, locale: Locale = .current) -> Label? {
        let formatter = HMCountFormatter(locale: locale)
        if let audienceCount {
            let count = max(0, audienceCount)
            return Label(compact: formatter.string(from: count), exact: String(count), unit: .watching)
        }
        if let viewCount {
            let count = max(0, viewCount)
            return Label(compact: formatter.string(from: count), exact: String(count), unit: .views)
        }
        return nil
    }
    /// Creates this component with host-supplied data and actions.
    public init(audienceCount: Int?, viewCount: Int? = nil) {
        self.audienceCount = audienceCount; self.viewCount = viewCount
    }
    /// Renders the component using current observable data and environment theme.
    public var body: some View {
        if let label = Self.label(audienceCount: audienceCount, viewCount: viewCount) {
            let shown = audienceCount ?? viewCount ?? 0
            HStack(spacing: 4) {
                theme.image(for: .audience).font(theme.fonts.caption)
                text(for: label)
                    .font(theme.fonts.caption.monospacedDigit())
                    .contentTransition(reduceMotion ? .identity : .numericText(value: Double(shown)))
            }
            .foregroundStyle(theme.colors.onVideo)
            .animation(reduceMotion ? nil : .default, value: shown)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText(for: label))
            .accessibilityIdentifier("hm-audience-badge")
        }
    }
    private func text(for label: Label) -> Text {
        switch label.unit {
        case .watching: return Text("\(label.compact) watching")
        case .views: return Text("\(label.compact) views")
        }
    }
    private func accessibilityText(for label: Label) -> Text {
        switch label.unit {
        case .watching: return Text("\(label.exact) watching")
        case .views: return Text("\(label.exact) views")
        }
    }
}
#endif
