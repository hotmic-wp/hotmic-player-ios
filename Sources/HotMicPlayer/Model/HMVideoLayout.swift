import Foundation

/// Nonnegative point insets in surface coordinates, independent of UI framework.
public struct HMVideoInsets: Sendable, Equatable {
    /// Reserved height at the top edge, in points.
    public var top: CGFloat
    /// Reserved width at the left edge, in points.
    public var left: CGFloat
    /// Reserved height at the bottom edge, in points.
    public var bottom: CGFloat
    /// Reserved width at the right edge, in points.
    public var right: CGFloat
    /// Creates point insets. Negative or nonfinite values are treated as zero when applied.
    public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
    }
    /// No reserved space at any edge.
    public static let zero = Self()
    func inset(_ bounds: CGRect) -> CGRect {
        func valid(_ v: CGFloat) -> CGFloat { v.isFinite ? max(0, v) : 0 }
        let x = min(bounds.width, valid(left)), y = min(bounds.height, valid(top))
        return CGRect(x: bounds.minX + x, y: bounds.minY + y,
                      width: max(0, bounds.width - x - valid(right)), height: max(0, bounds.height - y - valid(bottom)))
    }
}

/// Rendering-only layout. Changing it never seeks, assigns, or activates a player node.
public struct HMVideoLayout: Sendable, Equatable {
    /// Space reserved for host chrome, such as persistent bottom navigation.
    public var contentInsets: HMVideoInsets
    /// Optional squeeze viewport in surface coordinates. Clipped to the inset viewport.
    /// Update on every sheet drag frame, or use the host's SwiftUI animation transaction.
    public var squeezeTarget: CGRect?
    /// Creates a rendering layout with optional host chrome and an interactive squeeze viewport.
    public init(contentInsets: HMVideoInsets = .zero, squeezeTarget: CGRect? = nil) {
        self.contentInsets = contentInsets; self.squeezeTarget = squeezeTarget
    }
    /// Visible video bounds, with automatic policy resolved before squeeze (same as overlay snapshots).
    public func videoFrame(aspectRatio: Double?, presentation: HMVideoPresentation = .automatic,
                           in bounds: CGRect, tolerance: Double = 0.25) -> CGRect {
        let original = Self(contentInsets: contentInsets).viewport(in: bounds)
        let policy = presentation.resolved(aspectRatio: aspectRatio, container: original.size, tolerance: tolerance)
        return policy.videoFrame(aspectRatio: aspectRatio, in: viewport(in: bounds), tolerance: tolerance)
    }
    /// Insets the host bounds, then clips the optional target. Invalid targets fall back to the inset viewport.
    public func viewport(in bounds: CGRect) -> CGRect {
        let available = contentInsets.inset(bounds)
        guard let target = squeezeTarget else { return available }
        guard target.origin.x.isFinite, target.origin.y.isFinite, target.width.isFinite, target.height.isFinite,
              target.width >= 0, target.height >= 0 else { return available }
        let clipped = available.intersection(target)
        return clipped.isNull ? CGRect(origin: available.origin, size: .zero) : clipped
    }
}

/// Geometry shared by native and SwiftUI hosts. All rectangles use surface coordinates.
public enum HMOverlayRegions {
    /// Tests the entire candidate against the available area and reservations, even across freeRect bands.
    public static func isFree(_ rect: CGRect, videoFrame: CGRect, in bounds: CGRect,
                              safeArea: HMVideoInsets = .zero, contentInsets: HMVideoInsets = .zero,
                              excluding regions: [CGRect] = []) -> Bool {
        let base = available(videoFrame: videoFrame, in: bounds, safeArea: safeArea, contentInsets: contentInsets)
        return !rect.isNull && !rect.isEmpty && rect.origin.x.isFinite && rect.origin.y.isFinite &&
            rect.width.isFinite && rect.height.isFinite && base.contains(rect) &&
            regions.allSatisfy { rect.intersection($0).isEmpty || rect.intersection($0).isNull }
    }
    private static func available(videoFrame: CGRect, in bounds: CGRect, safeArea: HMVideoInsets, contentInsets: HMVideoInsets) -> CGRect {
        let insets = HMVideoInsets(top: max(safeArea.top, contentInsets.top), left: max(safeArea.left, contentInsets.left),
                                   bottom: max(safeArea.bottom, contentInsets.bottom), right: max(safeArea.right, contentInsets.right))
        return videoFrame.intersection(insets.inset(bounds))
    }
    /// True only on visible video outside registered hit areas. Rectangle edges are excluded too.
    public static func acceptsTap(at point: CGPoint, videoFrame: CGRect, excluding regions: [CGRect]) -> Bool {
        func contains(_ rect: CGRect) -> Bool {
            !rect.isNull && !rect.isEmpty && point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
        }
        return contains(videoFrame) && !regions.contains(where: contains)
    }
    /// Disjoint free rectangles inside video, safe area and content insets, after subtracting reservations.
    /// These are partition bands, not maximal rectangles. Use isFree to validate a candidate spanning bands.
    /// Safe area and nav insets are combined with max (not added) on each edge.
    public static func freeRects(videoFrame: CGRect, in bounds: CGRect, safeArea: HMVideoInsets = .zero,
                                 contentInsets: HMVideoInsets = .zero, excluding regions: [CGRect] = []) -> [CGRect] {
        let base = available(videoFrame: videoFrame, in: bounds, safeArea: safeArea, contentInsets: contentInsets)
        guard !base.isNull, !base.isEmpty else { return [] }
        return regions.reduce([base]) { free, reserved in
            free.flatMap { rect -> [CGRect] in
                let cut = rect.intersection(reserved)
                guard !cut.isNull, !cut.isEmpty else { return [rect] }
                return [CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cut.minY - rect.minY),
                        CGRect(x: rect.minX, y: cut.maxY, width: rect.width, height: rect.maxY - cut.maxY),
                        CGRect(x: rect.minX, y: cut.minY, width: cut.minX - rect.minX, height: cut.height),
                        CGRect(x: cut.maxX, y: cut.minY, width: rect.maxX - cut.maxX, height: cut.height)].filter { !$0.isEmpty }
            }
        }
    }
}
