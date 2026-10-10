import Foundation
import Testing
@testable import HotMicPlayer

@Suite("Host overlay layout and gestures")
struct LayoutGestureTests {
    @Test("Presentation resolves relative aspect, invalid hints and exact fit bounds")
    func presentationGeometry() {
        // Preserve explicitly named initializer references as well as ordinary call sites.
        let legacyURL = HMMediaItem.init(id:url:format:posterURL:title:author:durationHint:metadata:)
        let legacySource = HMMediaItem.init(id:source:posterURL:title:author:durationHint:metadata:)
        let url = URL(string: "https://example.com/a.mp4")!
        #expect(legacyURL("legacy", url, .auto, nil, nil, nil, nil, [:]).aspectRatio == nil)
        #expect(legacySource("legacy", .url(url, format: .auto), nil, nil, nil, nil, [:]).presentation == nil)
        let bounds = CGRect(x: 10, y: 20, width: 390, height: 844)
        #expect(HMVideoPresentation.automatic.resolved(aspectRatio: 16.0/9, container: bounds.size) == .fit)
        #expect(HMVideoPresentation.automatic.resolved(aspectRatio: 9.0/16, container: CGSize(width: 390, height: 800)) == .fill)
        #expect(HMVideoPresentation.automatic.resolved(aspectRatio: nil, container: bounds.size) == .fill)
        #expect(HMVideoPresentation.automatic.resolved(aspectRatio: .nan, container: bounds.size) == .fill)
        #expect(HMVideoPresentation.automatic.resolved(aspectRatio: 1, container: CGSize(width: 100, height: 100), tolerance: 0) == .fill)
        for policy in [HMVideoPresentation.fit, .fitWithColor, .fitWithBlurredBackdrop, .automatic] {
            let frame = policy.videoFrame(aspectRatio: 16.0/9, in: bounds)
            #expect(frame.width == 390 && abs(frame.height - 219.375) < 0.001)
            #expect(frame.midX == bounds.midX && frame.midY == bounds.midY)
        }
        #expect(HMVideoPresentation.fill.videoFrame(aspectRatio: 16.0/9, in: bounds) == bounds)
        #expect(HMVideoPresentation.fit.videoFrame(aspectRatio: 0, in: bounds) == bounds)
        #expect(HMVideoPresentation.fit.videoFrame(aspectRatio: 16.0/9, in: .zero) == .zero)
        for invalid in [0.0, -1, .infinity, .nan] {
            #expect(HMMediaItem(id: "invalid", url: URL(string: "https://example.com/a.mp4")!, aspectRatio: invalid).aspectRatio == nil)
        }
    }
    @Test("Compact social count boundaries, rounding, suffixes, negatives and localized digits")
    func counts() {
        let formatter = HMCountFormatter(locale: Locale(identifier: "en_US"))
        let values: [(Int, String)] = [(0, "0"), (-1, "0"), (999, "999"), (1_000, "1K"),
            (1_049, "1K"), (1_050, "1.1K"), (999_949, "999.9K"), (999_950, "1M"),
            (999_999, "1M"), (1_000_000, "1M"), (1_050_000, "1.1M"), (999_949_999, "999.9M"), (999_950_000, "1B"), (999_999_999, "1B"), (1_000_000_000, "1B"), (1_050_000_000, "1.1B"), (Int.max, "9223372036.9B")]
        for (count, expected) in values { #expect(formatter.string(from: count) == expected) }
        #expect(HMCountFormatter(locale: Locale(identifier: "de_DE")).string(from: 1_250) == "1,3K")
        #expect(HMCountFormatter(locale: Locale(identifier: "ar_EG")).string(from: 1_250) == "١٫٣K")
    }
    @Test("Insets and squeeze clip to host bounds while fill and fit keep their policies")
    func squeezeGeometry() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        var layout = HMVideoLayout(contentInsets: HMVideoInsets(bottom: 88))
        #expect(layout.viewport(in: bounds) == CGRect(x: 0, y: 0, width: 390, height: 756))
        layout.squeezeTarget = CGRect(x: -20, y: 60, width: 450, height: 300)
        let viewport = layout.viewport(in: bounds)
        #expect(viewport == CGRect(x: 0, y: 60, width: 390, height: 300))
        #expect(HMVideoPresentation.fill.videoFrame(aspectRatio: 9.0/16, in: viewport) == viewport)
        let fit = HMVideoPresentation.fit.videoFrame(aspectRatio: 16.0/9, in: viewport)
        #expect(fit.width == 390 && fit.midY == 210)
        #expect(layout.videoFrame(aspectRatio: 9.0/16, in: bounds) == viewport) // automatic remains fill during squeeze
        #expect(layout.videoFrame(aspectRatio: 16.0/9, in: bounds) == fit)
        layout.squeezeTarget = CGRect(x: 0, y: 900, width: 390, height: 40)
        #expect(layout.viewport(in: bounds).isEmpty)
        layout.squeezeTarget = CGRect(x: CGFloat.nan, y: 0, width: 390, height: 40)
        #expect(layout.viewport(in: bounds).height == 756)
        layout.contentInsets.bottom = 1_000
        #expect(layout.viewport(in: bounds).isEmpty)
    }
    @Test("Hit edges, fit bars and overlapping reservations never receive video taps; free areas are disjoint")
    func exclusions() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        let video = CGRect(x: 0, y: 20, width: 400, height: 700)
        let regions = [CGRect(x: 320, y: 200, width: 80, height: 400),
                       CGRect(x: 20, y: 500, width: 310, height: 180)]
        for point in [CGPoint(x: 320, y: 200), CGPoint(x: 330, y: 550), CGPoint(x: 40, y: 600), CGPoint(x: 200, y: 10), CGPoint(x: 200, y: 750)] {
            #expect(!HMOverlayRegions.acceptsTap(at: point, videoFrame: video, excluding: regions))
        }
        #expect(HMOverlayRegions.acceptsTap(at: CGPoint(x: 200, y: 300), videoFrame: video, excluding: regions))
        let free = HMOverlayRegions.freeRects(videoFrame: video, in: bounds, safeArea: HMVideoInsets(top: 60, bottom: 34),
            contentInsets: HMVideoInsets(bottom: 100), excluding: regions + [regions[0]])
        #expect(!free.isEmpty)
        for (i, rect) in free.enumerated() {
            #expect(rect.minY >= 60 && rect.maxY <= 700)
            #expect(regions.allSatisfy { rect.intersection($0).isEmpty })
            for other in free.dropFirst(i + 1) { #expect(rect.intersection(other).isEmpty) }
        }
        #expect(HMOverlayRegions.freeRects(videoFrame: video, in: bounds, excluding: [bounds]).isEmpty)
        // A valid sidecar can straddle partition bands cut by a reservation far to its left.
        let obstacle = CGRect(x: 0, y: 200, width: 100, height: 200)
        let candidate = CGRect(x: 300, y: 100, width: 80, height: 400)
        let bands = HMOverlayRegions.freeRects(videoFrame: video, in: bounds, excluding: [obstacle])
        #expect(!bands.contains { $0.contains(candidate) })
        #expect(HMOverlayRegions.isFree(candidate, videoFrame: video, in: bounds, excluding: [obstacle]))
        #expect(!HMOverlayRegions.isFree(candidate, videoFrame: video, in: bounds, safeArea: HMVideoInsets(right: 40)))
        #expect(!HMOverlayRegions.isFree(candidate, videoFrame: video, in: bounds, excluding: [candidate]))
        #expect(!HMOverlayRegions.isFree(CGRect(x: 300, y: 100, width: 80, height: 650), videoFrame: video, in: bounds, contentInsets: HMVideoInsets(bottom: 100)))
        #expect(!HMOverlayRegions.isFree(.null, videoFrame: video, in: bounds))
    }
}
