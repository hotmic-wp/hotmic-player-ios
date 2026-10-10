#if canImport(UIKit) && !os(watchOS)
import SwiftUI
import MediaAccessibility
import CoreText
import UIKit

struct HMCaptionOverlay: UIViewRepresentable {
    let controller: HMCaptionController
    let text: String
    let videoFrame: CGRect
    let safeArea: HMVideoInsets
    let insets: HMVideoInsets
    let regions: [CGRect]
    let coordinateReference: (() -> UIView?)?
    let hostRegions: [CGRect]
    let useNative: Bool
    let styleRevision: Int
    func makeUIView(context: Context) -> HMCaptionOverlayView { HMCaptionOverlayView() }
    func updateUIView(_ view: HMCaptionOverlayView, context: Context) {
        controller.renderInOverlay(!useNative)
        let reference = coordinateReference?()
        let local = regions.filter { !hostRegions.contains($0) } + hostRegions.map { rect in reference.map { view.convert(rect, from: $0) } ?? rect }
        view.update(text: useNative ? "" : text, videoFrame: videoFrame, safeArea: safeArea, insets: insets, regions: local, styleRevision: styleRevision)
    }
}

final class HMCaptionOverlayView: UIView {
    let label = UILabel()
    private var videoFrame = CGRect.zero
    private var safeArea = HMVideoInsets.zero
    private var insets = HMVideoInsets.zero
    private var regions: [CGRect] = []
    private var styleRevision = -1
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        label.numberOfLines = 0; label.textAlignment = .center
        label.accessibilityIdentifier = "hm-caption-text"
        // Captions are readable text, without repetitive VoiceOver announcements on every cue.
        label.isAccessibilityElement = false
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(text: String, videoFrame: CGRect, safeArea: HMVideoInsets, insets: HMVideoInsets, regions: [CGRect], styleRevision: Int = 0) {
        if self.videoFrame != videoFrame || self.safeArea != safeArea || self.insets != insets || self.regions != regions { setNeedsLayout() }
        self.videoFrame = videoFrame; self.safeArea = safeArea; self.insets = insets; self.regions = regions
        guard label.text != text || self.styleRevision != styleRevision else { return }
        self.styleRevision = styleRevision
        let scale = MACaptionAppearanceGetRelativeCharacterSize(.user, nil)
        let size = scale.isFinite && scale > 0 ? 20 * scale : 20
        let descriptor = MACaptionAppearanceCopyFontDescriptorForStyle(.user, nil, .default).takeRetainedValue()
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        let uiFont = UIFont(name: CTFontCopyPostScriptName(font) as String, size: size) ?? UIFont.systemFont(ofSize: size)
        let foreground = UIColor(cgColor: MACaptionAppearanceCopyForegroundColor(.user, nil).takeRetainedValue())
            .withAlphaComponent(MACaptionAppearanceGetForegroundOpacity(.user, nil))
        let background = UIColor(cgColor: MACaptionAppearanceCopyBackgroundColor(.user, nil).takeRetainedValue())
            .withAlphaComponent(MACaptionAppearanceGetBackgroundOpacity(.user, nil))
        label.backgroundColor = UIColor(cgColor: MACaptionAppearanceCopyWindowColor(.user, nil).takeRetainedValue())
            .withAlphaComponent(MACaptionAppearanceGetWindowOpacity(.user, nil))
        label.layer.cornerRadius = MACaptionAppearanceGetWindowRoundedCornerRadius(.user, nil)
        label.clipsToBounds = true
        var attributes: [NSAttributedString.Key: Any] = [.font: uiFont, .foregroundColor: foreground, .backgroundColor: background]
        let edge = MACaptionAppearanceGetTextEdgeStyle(.user, nil)
        if edge != .none && edge != .undefined {
            let shadow = NSShadow(); shadow.shadowColor = UIColor.black; shadow.shadowBlurRadius = 2
            shadow.shadowOffset = CGSize(width: edge == .raised ? -1 : 1, height: edge == .raised ? -1 : 1)
            shadow.shadowBlurRadius = edge == .dropShadow ? 2 : 0
            attributes[.shadow] = shadow
            if edge == .uniform { attributes[.strokeColor] = UIColor.black; attributes[.strokeWidth] = -2 }
        }
        label.attributedText = NSAttributedString(string: text, attributes: attributes)
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard label.text?.isEmpty == false else { label.isHidden = true; return }
        let free = HMOverlayRegions.freeRects(videoFrame: videoFrame, in: bounds, safeArea: safeArea, contentInsets: insets, excluding: regions)
        // Prefer the lowest region with room for the complete measured cue. Never shrink text to force a collision.
        let candidates = free.compactMap { region -> CGRect? in
            let area = region.insetBy(dx: 12, dy: 12)
            guard area.width >= 100, area.height > 0 else { return nil }
            let measured = label.sizeThatFits(CGSize(width: min(600, area.width), height: .greatestFiniteMagnitude))
            guard measured.height <= area.height else { return nil }
            return CGRect(x: area.midX - min(600, area.width) / 2, y: area.maxY - measured.height,
                          width: min(600, area.width), height: measured.height)
        }
        guard let frame = candidates.sorted(by: { $0.maxY == $1.maxY ? $0.width > $1.width : $0.maxY > $1.maxY }).first else {
            label.isHidden = true; return
        }
        label.isHidden = false; label.frame = frame
    }
}
#endif
