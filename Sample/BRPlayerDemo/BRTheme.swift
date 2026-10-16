import SwiftUI
import HotMicPlayerUI

/// B/R's look for the demo, as `HMTheme` values only: white outline glyphs straight on the video,
/// condensed heavy titles, B/R violet for the follow badge and links, a hot orange for a lit Fire.
/// Reference: the rail and Squeezeback images in B/R's Midroll document. B/R's own design pass
/// replaces these values later; nothing here lives in the SDK.
enum BRTheme {
    /// Follow badge, links, the viewer's own vote.
    static let violet = Color(red: 0.49, green: 0.29, blue: 0.98)
    /// A lit Fire.
    static let fire = Color(red: 1.0, green: 0.42, blue: 0.13)

    static var theme: HMTheme {
        var theme = HMTheme(
            colors: HMTheme.Colors(
                accent: violet,
                accentSecondary: fire,
                author: .white,
                onVideo: .white,
                onVideoSecondary: .white.opacity(0.72),
                scrim: .black,
                cardTint: .black.opacity(0.35),
                track: .white.opacity(0.3)
            ),
            fonts: HMTheme.Fonts(
                body: .system(.subheadline),
                emphasis: .system(.subheadline, weight: .semibold),
                caption: .system(.caption, weight: .semibold),
                headline: .system(.title3, weight: .heavy).width(.condensed),
                metric: .system(.footnote, weight: .semibold).monospacedDigit()
            ),
            icons: HMTheme.Icons(
                react: "flame",
                comment: "text.bubble",
                share: "arrowshape.turn.up.right",
                send: "paperplane.fill",
                muted: "speaker.slash",
                unmuted: "speaker.wave.2",
                poll: "chart.bar",
                selected: "checkmark.circle.fill"
            ),
            cornerRadius: 10,
            reactionPalette: ["🔥", "😂", "😮", "👏", "🏆"],
            messageReaction: "🔥"
        )
        theme.railSpacing = 12
        theme.audienceSymbol = "eye"
        return theme
    }

    /// Text and glyphs drawn straight on video keep a soft shadow instead of a scrim box.
    static let videoShadow = Color.black.opacity(0.55)
}
