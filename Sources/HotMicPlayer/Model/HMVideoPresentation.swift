import Foundation

/// How video occupies its host's bounds. Changes affect rendering only, never playback.
public enum HMVideoPresentation: String, Sendable, Hashable, Codable {
    /// Fill when the relative aspect difference is within `aspectRatioTolerance`; otherwise fit.
    /// Unknown aspect preserves the historical fill behavior until a hint or decoded size arrives.
    case automatic
    /// Crop to fill the host while preserving aspect.
    case fill
    /// Show the entire video with black bars.
    case fit
    /// Fit over a blurred, darkened poster, using no additional decoder.
    /// Without a supplied poster, the surface captures a small still from its existing decoded output.
    case fitWithBlurredBackdrop
    /// Fit over the configured `backdropColor`.
    /// Show the entire video over the configured RGBA color.
    case fitWithColor

    /// Resolves automatic policy. Tolerance is a relative difference (0.25 means 25%).
    public func resolved(aspectRatio: Double?, container: CGSize, tolerance: Double = 0.25) -> Self {
        guard self == .automatic else { return self }
        guard let aspect = HMVideoAspect.valid(aspectRatio), container.width > 0, container.height > 0 else { return .fill }
        let difference = abs(aspect / Double(container.width / container.height) - 1)
        return difference <= (tolerance.isFinite ? max(0, tolerance) : 0.25) ? .fill : .fit
    }

    /// Visible video rect in host coordinates; fill occupies the entire host, fit excludes the bars.
    public func videoFrame(aspectRatio: Double?, in bounds: CGRect, tolerance: Double = 0.25) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let policy = resolved(aspectRatio: aspectRatio, container: bounds.size, tolerance: tolerance)
        guard policy != .fill, let aspect = HMVideoAspect.valid(aspectRatio) else { return bounds }
        let width = min(bounds.width, bounds.height * aspect)
        let height = width / aspect
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }
}

/// Portable RGBA color for video bars. Components are clamped by the renderer.
public struct HMVideoBackdropColor: Sendable, Hashable, Codable {
    /// Red channel, rendered within 0...1.
    public var red: Double
    /// Green channel, rendered within 0...1.
    public var green: Double
    /// Blue channel, rendered within 0...1.
    public var blue: Double
    /// Opacity, rendered within 0...1.
    public var alpha: Double
    /// Creates a portable bar color. Nonfinite components render as zero.
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    /// Opaque black, the default bar color.
    public static let black = Self(red: 0, green: 0, blue: 0)
}

/// Aspect validation shared by hints, transformed tracks and decoded presentation sizes.
enum HMVideoAspect {
    static func valid(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
    static func ratio(_ size: CGSize) -> Double? {
        guard size.width.isFinite, size.height.isFinite, size.width != 0, size.height != 0 else { return nil }
        return valid(abs(Double(size.width / size.height)))
    }
}
