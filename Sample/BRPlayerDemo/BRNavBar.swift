import SwiftUI

/// Stand-in for B/R's persistent bottom navigation (Vertical Video 1.1). The kit reserves its
/// height through `HMSocialOptions.hostNavigationHeight`; the bar itself is the host's to draw.
/// Home opens the Home stand-in; Watch is the feed; the other tabs are inert.
struct BRNavBar: View {
    /// Content height, excluding the home-indicator safe area.
    static let height: CGFloat = 54
    enum Tab: String, CaseIterable {
        case home = "Home", scores = "Scores", watch = "Watch", search = "Search", inbox = "Inbox"
        var symbol: String {
            switch self {
            case .home: return "house.fill"
            case .scores: return "sportscourt.fill"
            case .watch: return "play.rectangle.fill"
            case .search: return "magnifyingglass"
            case .inbox: return "tray.fill"
            }
        }
    }
    let selected: Tab
    let onSelect: (Tab) -> Void
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button { onSelect(tab) } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol).font(.system(size: 19, weight: .semibold))
                        Text(tab.rawValue).font(.system(size: 10, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(tab == selected ? Color.white : Color.white.opacity(0.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == selected ? .isSelected : [])
                .accessibilityIdentifier("br-nav-\(tab.rawValue.lowercased())")
            }
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.15)).frame(height: 0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("br-nav-bar")
    }
}
