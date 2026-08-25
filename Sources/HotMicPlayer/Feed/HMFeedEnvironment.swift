#if canImport(SwiftUI)
import SwiftUI

private struct HMFeedSafeAreaKey: EnvironmentKey {
    static let defaultValue = EdgeInsets()
}

public extension EnvironmentValues {
    /// Safe-area insets of the feed's container.
    ///
    /// A full-bleed feed has to ignore the safe area to reach the screen edges,
    /// which zeroes out the insets everything inside it would normally read.
    /// The feed measures them before it expands and republishes them here, so
    /// overlays can still keep their chrome clear of the notch and home bar.
    var hmFeedSafeArea: EdgeInsets {
        get { self[HMFeedSafeAreaKey.self] }
        set { self[HMFeedSafeAreaKey.self] = newValue }
    }
}
#endif
