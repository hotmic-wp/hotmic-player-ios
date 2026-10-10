# Theming

Apply your brand once and let every component read it from the SwiftUI environment.

## Start from the default

```swift
import HotMicPlayerUI

var theme = HMTheme.default
// Configure on the main actor, above the feed or component subtree.
theme.colors.accent = .orange
theme.colors.accentSecondary = .yellow
theme.icons.share = "paperplane"
theme.reactionPalette = ["👏", "🔥", "💜"]
theme.messageReaction = "💜"
theme.cornerRadius = 16
feed.hmTheme(theme)
```

``HMTheme`` groups colors, Dynamic Type fonts, SF Symbol names, card corner radius, stream reaction palette, and the double-tap message reaction. A tap sends `primaryReaction`, the first palette emoji. Empty palettes fall back to the default fire emoji.

`colors.onVideo` and `onVideoSecondary` draw over video; keep them legible against the scrim. Cards use system material and adapt to appearance. Use semantic SwiftUI fonts in `fonts` to retain Dynamic Type. `fonts.metric` should use monospaced digits so ticking timecodes do not shift layout. Every icon value is an SF Symbol name.

## Options and precedence

`hmTheme(_:)` and `hmOverlayOptions(_:)` apply to all descendants. The nearest environment modifier wins. An explicit `HMOverlayLayout.Options` supplied to an overlay initializer takes priority over environment options.

Options select chat, polls, reactions, metadata, scrubber and playback tap handling; choose individual action buttons, chat lookback/limit, share handling, and extra content insets. A hidden region is not constructed. Source capabilities still control whether actions exist.

## Accessibility

Keep VoiceOver labels meaningful when replacing controls. Built-in components provide action labels and the scrubber adjusts in ten-second steps. Reduce Motion replaces travel with fades and disables ambient floating reactions. Larger accessibility text sizes show fewer, larger chat lines. Check your palette, scrim and fonts in both appearances and at accessibility sizes on your target devices.

Use [Examples/PlayerWithUI](https://github.com/hotmic-wp/hotmic-player-ios/tree/main/Examples/PlayerWithUI) to preview the orange/yellow theme, or the full Sample for layout and accessibility exploration.
