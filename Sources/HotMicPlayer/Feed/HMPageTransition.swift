#if canImport(SwiftUI)
import SwiftUI

/// How a cell animates as it moves through the viewport.
///
/// Each case resolves to a plain value struct rather than a view modifier chain,
/// so the feed can apply one uniform `visualEffect` for every transition. That
/// keeps the effect on the render-server path and avoids re-laying-out cells
/// mid-scroll.
public enum HMPageTransition: String, CaseIterable, Sendable, Identifiable {
    /// Straight paging, no decoration. Fastest, and what most feeds ship.
    case none
    /// Outgoing cell dims as it leaves.
    case fade
    /// Neighbours sit slightly back in Z.
    case scale
    /// Content moves slower than the page — adds depth on swipe.
    case parallax
    /// Pages hinge like faces of a cube.
    case cube
    /// Incoming page slides over the outgoing one, which stays put.
    case cover

    /// Stable identity for this value.
    public var id: String { rawValue }

    /// Human-readable transition name.
    public var displayName: String {
        switch self {
        case .none: "None"
        case .fade: "Fade"
        case .scale: "Scale"
        case .parallax: "Parallax"
        case .cube: "Cube"
        case .cover: "Cover"
        }
    }

    /// Resolved transform for one cell.
    public struct Attributes: Equatable {
        /// Resolved cell opacity.
        public var opacity: Double = 1
        /// Resolved cell scale factor.
        public var scale: Double = 1
        /// Resolved vertical translation in points.
        public var offsetY: Double = 0
        /// Resolved rotation in degrees.
        public var rotationDegrees: Double = 0
        /// Anchor used for the cell rotation.
        public var anchor: UnitPoint = .center
        /// Perspective applied to the cell rotation.
        public var perspective: Double = 0.5
    }

    /// - Parameters:
    ///   - offset: normalised distance from the viewport centre, in pages
    ///     (`-1` = one page above, `0` = centred, `1` = one page below).
    ///   - height: page height in points.
    public func attributes(offset: Double, height: Double) -> Attributes {
        let clamped = max(-1.5, min(1.5, offset))
        let distance = abs(clamped)
        var attributes = Attributes()

        switch self {
        case .none:
            break
        case .fade:
            attributes.opacity = max(0, 1 - distance * 1.2)
        case .scale:
            attributes.scale = max(0.86, 1 - distance * 0.14)
            attributes.opacity = max(0.2, 1 - distance * 0.6)
        case .parallax:
            attributes.offsetY = -clamped * height * 0.18
            attributes.opacity = max(0.25, 1 - distance * 0.5)
        case .cube:
            attributes.rotationDegrees = clamped * -55
            attributes.anchor = clamped > 0 ? .top : .bottom
            attributes.perspective = 0.55
            attributes.opacity = max(0, 1 - distance * 0.9)
        case .cover:
            // Hold the outgoing page still; only the incoming one moves.
            attributes.offsetY = clamped < 0 ? -clamped * height : 0
            attributes.opacity = clamped < -1 ? 0 : 1
        }
        return attributes
    }
}
#endif
