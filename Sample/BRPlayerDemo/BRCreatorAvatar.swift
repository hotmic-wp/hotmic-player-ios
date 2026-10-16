import SwiftUI
import HotMicPlayerUI

/// The creator's avatar on the rail. The catalog has a handle and a name but no images, so it
/// draws a monogram tinted per handle, with B/R's violet follow "+" on its lower edge and the
/// handle underneath. Following is your app's; here it only flips the badge to a check.
struct BRCreatorAvatar: View {
    let handle: String
    let name: String
    @State private var following = false
    @Environment(\.hmTheme) private var theme
    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 40

    var body: some View {
        VStack(spacing: 6) {
            Button { following.toggle() } label: {
                Text(monogram)
                    .font(.system(size: size * 0.38, weight: .heavy).width(.condensed))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(tint, in: Circle())
                    .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                    .overlay(alignment: .bottom) {
                        Image(systemName: following ? "checkmark" : "plus")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 16, height: 16)
                            .background(following ? Color.white.opacity(0.25) : theme.colors.accent, in: Circle())
                            .offset(y: 8)
                    }
                    .frame(minWidth: 52, minHeight: 52)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(following ? "Following \(name)" : "Follow \(name)")
            .accessibilityIdentifier("br-follow")
            Text(handle.hasPrefix("@") ? String(handle.dropFirst()) : handle)
                .font(theme.fonts.caption).lineLimit(1).fixedSize()
                .accessibilityHidden(true)
        }
        .shadow(color: BRTheme.videoShadow, radius: 4, y: 1)
    }

    /// "B/R Hoops" → "H", "B/R Open Ice" → "OI": every demo creator is a B/R channel, so the
    /// brand prefix is dropped and the first letters of the first and last remaining words stay.
    private var monogram: String {
        let words = name.split(separator: " ").filter { $0 != "B/R" && $0.first?.isLetter == true }
        let letters = [words.first, words.count > 1 ? words.last : nil].compactMap { $0?.first }
        return letters.isEmpty ? "BR" : String(letters).uppercased()
    }

    /// Stable per handle across launches, unlike `hashValue`.
    private var tint: Color {
        var hash: UInt64 = 5381
        for byte in handle.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.55, brightness: 0.45)
    }
}
