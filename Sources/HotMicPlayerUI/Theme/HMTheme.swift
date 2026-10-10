#if os(iOS)
import SwiftUI

/// The look of every HotMicPlayerUI component: colors, fonts, corner radius, icons
/// and the reaction palette.
///
/// A value type, applied with `.hmTheme(_:)` anywhere above the components; each
/// component reads it from the environment, so a single modifier restyles a whole
/// layout. Fonts are Dynamic Type text styles, so they scale with the viewer's setting.
///
/// ```swift
/// var theme = HMTheme.default
/// theme.colors.accent = .orange
/// theme.icons.share = "paperplane"
/// HMVerticalFeedView(player: player, layout: HMOverlayLayout.self).hmTheme(theme)
/// ```
///
/// Configure this SwiftUI value on the main actor.
public struct HMTheme {

    /// Palette. Content drawn directly on video uses the `onVideo` colors; cards
    /// (poll, composer) use system materials and adapt to light and dark mode.
    ///
    /// Configure this SwiftUI value on the main actor.
    public struct Colors {
        /// Brand accent: the watched waveform, the viewer's vote, send button.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var accent: Color
        /// Second gradient stop for the waveform and reaction highlights.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var accentSecondary: Color
        /// Author names in chat. Lighter than `accent` so it reads on dark video.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var author: Color
        /// Primary text and icons over video.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var onVideo: Color
        /// Secondary text over video.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var onVideoSecondary: Color
        /// Gradient scrim color behind content over video.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var scrim: Color
        /// Tint layered over the card material.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var cardTint: Color
        /// Unwatched waveform bars.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var track: Color

        /// Creates a palette.
        ///
        /// Configure this SwiftUI value on the main actor.
        public init(accent: Color, accentSecondary: Color, author: Color, onVideo: Color, onVideoSecondary: Color,
                    scrim: Color, cardTint: Color, track: Color) {
            self.accent = accent
            self.accentSecondary = accentSecondary
            self.author = author
            self.onVideo = onVideo
            self.onVideoSecondary = onVideoSecondary
            self.scrim = scrim
            self.cardTint = cardTint
            self.track = track
        }
    }

    /// Type ramp. Each is a Dynamic Type text style.
    ///
    /// Configure this SwiftUI value on the main actor.
    public struct Fonts {
        /// Chat text and poll options.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var body: Font
        /// Author names and the item's author.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var emphasis: Font
        /// Counts, labels and metadata.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var caption: Font
        /// Poll question.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var headline: Font
        /// Timecodes and anything that ticks; should use monospaced digits.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var metric: Font

        /// Creates a type ramp.
        ///
        /// Configure this SwiftUI value on the main actor.
        public init(body: Font, emphasis: Font, caption: Font, headline: Font, metric: Font) {
            self.body = body
            self.emphasis = emphasis
            self.caption = caption
            self.headline = headline
            self.metric = metric
        }
    }

    /// SF Symbol names for every control.
    ///
    /// Configure this SwiftUI value on the main actor.
    public struct Icons {
        /// Stream reaction button.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var react: String
        /// Opens the composer.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var comment: String
        /// Share placeholder.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var share: String
        /// Sends a chat message.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var send: String
        /// Shown while muted.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var muted: String
        /// Shown while sound is on.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var unmuted: String
        /// Poll header.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var poll: String
        /// The viewer's poll choice.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var selected: String

        /// Creates an icon set.
        ///
        /// Configure this SwiftUI value on the main actor.
        public init(react: String, comment: String, share: String, send: String, muted: String, unmuted: String,
                    poll: String, selected: String) {
            self.react = react
            self.comment = comment
            self.share = share
            self.send = send
            self.muted = muted
            self.unmuted = unmuted
            self.poll = poll
            self.selected = selected
        }
    }

    /// Custom images override SF Symbol defaults for the social controls.
    public enum Icon: Hashable {
        /// Fire reaction icon, used by both the rail and burst.
        case fire
        /// Opens the comment sheet.
        case comment
        /// Opens host sharing UI.
        case share
        /// Audio is muted.
        case muted
        /// Audio is enabled.
        case unmuted
        /// Closed captions control.
        case captions
        /// Enters fullscreen playback.
        case fullscreen
        /// Playback affordance.
        case play
        /// Closes sheets or exits fullscreen.
        case close
    }
    /// Host images overriding the corresponding social SF Symbol icons.
    public var customImages: [Icon: Image] = [:]
    /// Vertical spacing between rail controls, in points.
    public var railSpacing: CGFloat = 14
    /// Seconds for a burst to resolve into the rail icon.
    public var fireAnimationDuration: TimeInterval = 0.5
    /// Seconds for sheet opening and closing; ignored for Reduce Motion.
    public var sheetAnimationDuration: TimeInterval = 0.25
    /// Fallback SF Symbol for the closed-caption control.
    public var captionsSymbol = "captions.bubble"
    /// Fallback SF Symbol for the fullscreen control.
    public var fullscreenSymbol = "arrow.up.left.and.arrow.down.right"
    /// Fallback SF Symbol for the paused playback affordance.
    public var playSymbol = "play.fill"
    /// Fallback SF Symbol for close and fullscreen exit controls.
    public var closeSymbol = "xmark"

    /// Resolves host images before falling back to the theme's symbols.
    public func image(for icon: Icon) -> Image {
        if let image = customImages[icon] { return image }
        let symbol: String
        switch icon {
        case .fire: symbol = icons.react
        case .comment: symbol = icons.comment
        case .share: symbol = icons.share
        case .muted: symbol = icons.muted
        case .unmuted: symbol = icons.unmuted
        case .captions: symbol = captionsSymbol
        case .fullscreen: symbol = fullscreenSymbol
        case .play: symbol = playSymbol
        case .close: symbol = closeSymbol
        }
        return Image(systemName: symbol)
    }

    /// Palette.
    ///
    /// Configure this SwiftUI value on the main actor.
    public var colors: Colors
    /// Type ramp.
    ///
    /// Configure this SwiftUI value on the main actor.
    public var fonts: Fonts
    /// Icons.
    ///
    /// Configure this SwiftUI value on the main actor.
    public var icons: Icons
    /// Corner radius for cards and the composer field.
    ///
    /// Configure this SwiftUI value on the main actor.
    public var cornerRadius: CGFloat
    /// Emoji offered by a long press on the react button. The first is what a tap sends.
    ///
    /// Configure this SwiftUI value on the main actor.
    public var reactionPalette: [String]
    /// Emoji a double-tap on a chat message sends.
    ///
    /// Configure this SwiftUI value on the main actor.
    public var messageReaction: String

    /// Creates a theme.
    ///
    /// Configure this SwiftUI value on the main actor.
    public init(colors: Colors, fonts: Fonts, icons: Icons, cornerRadius: CGFloat, reactionPalette: [String],
                messageReaction: String) {
        self.colors = colors
        self.fonts = fonts
        self.icons = icons
        self.cornerRadius = cornerRadius
        self.reactionPalette = reactionPalette.isEmpty ? ["🔥"] : reactionPalette
        self.messageReaction = messageReaction
    }

    /// Emoji a tap on the react button sends.
    ///
    /// Configure this SwiftUI value on the main actor.
    public var primaryReaction: String { reactionPalette.first ?? "🔥" }

    /// HotMic's look: near-black stage, violet-to-pink accent, rounded type.
    ///
    /// Configure this SwiftUI value on the main actor.
    public static let `default` = HMTheme(
        colors: Colors(
            accent: Color(red: 0.72, green: 0.38, blue: 1.0),
            accentSecondary: Color(red: 1.0, green: 0.33, blue: 0.55),
            author: Color(red: 0.84, green: 0.70, blue: 1.0),
            onVideo: .white,
            onVideoSecondary: .white.opacity(0.78),
            scrim: .black,
            cardTint: Color(red: 0.72, green: 0.38, blue: 1.0).opacity(0.06),
            track: .white.opacity(0.24)
        ),
        fonts: Fonts(
            body: .system(.subheadline, design: .rounded),
            emphasis: .system(.subheadline, design: .rounded, weight: .semibold),
            caption: .system(.caption, design: .rounded, weight: .medium),
            headline: .system(.headline, design: .rounded),
            metric: .system(.footnote, design: .rounded, weight: .semibold).monospacedDigit()
        ),
        icons: Icons(
            react: "flame.fill",
            comment: "bubble.right.fill",
            share: "arrowshape.turn.up.right.fill",
            send: "arrow.up.circle.fill",
            muted: "speaker.slash.fill",
            unmuted: "speaker.wave.2.fill",
            poll: "chart.bar.fill",
            selected: "checkmark.circle.fill"
        ),
        cornerRadius: 18,
        reactionPalette: ["🔥", "😂", "😮", "💜", "👏", "🏆"],
        messageReaction: "💜"
    )
}

private struct HMThemeKey: EnvironmentKey {
    static let defaultValue = HMTheme.default
}

public extension EnvironmentValues {
    /// Theme read by every HotMicPlayerUI component.
    ///
    /// Configure this SwiftUI value on the main actor.
    var hmTheme: HMTheme {
        get { self[HMThemeKey.self] }
        set { self[HMThemeKey.self] = newValue }
    }
}

public extension View {
    /// Applies a theme to every HotMicPlayerUI component inside this view.
    ///
    /// Access on the main actor.
    func hmTheme(_ theme: HMTheme) -> some View { environment(\.hmTheme, theme) }
}

extension View {
    /// Keeps light text legible over arbitrary video without a full scrim.
    func hmVideoLegible() -> some View { shadow(color: .black.opacity(0.5), radius: 5, y: 1) }

    /// Frosted card used by the poll card and composer; adapts to light and dark.
    func hmCard(_ theme: HMTheme) -> some View {
        background {
            RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous).fill(theme.colors.cardTint))
                .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        }
    }
}

/// Small shared formatting.
enum HMFormat {
    /// "0:42", "1:02:03".
    static func timecode(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "12", "1.2K", "3.4M".
    static func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    /// Spoken duration for VoiceOver: "1 minute, 2 seconds".
    static func spoken(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        return formatter.string(from: max(0, seconds.rounded(.down))) ?? HMFormat.timecode(seconds)
    }

    /// Stable across launches, unlike `hashValue`.
    static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 5381
        for byte in string.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return hash
    }
}
#endif
