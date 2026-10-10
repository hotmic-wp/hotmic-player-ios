import SwiftUI
import AVFoundation
import Observation
import HotMicPlayer

/// Host-built social chrome; this file uses only the SDK's public API.
struct SocialLayoutScreen: View {
    @State private var player = HMPlayer(configuration: HMPlayerConfiguration(startsMuted: true))
    @State private var model = SocialLayoutModel()
    var body: some View {
        GeometryReader { outer in
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    SocialFeed(player: player, model: model, size: geometry.size, safe: outer.safeAreaInsets)
                    SocialChrome(player: player, model: model, size: geometry.size, safe: outer.safeAreaInsets)
                }
            }.ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .task {
            player.configuration.presentation = .fill
            player.analytics.add(model.trace)
            do {
                if let fixture = BenchmarkOptions().values["social-fixture"] {
                    let landscape = fixture == "landscape"
                    player.replaceAll([HMMediaItem(id: "social-fixture", url: try await socialVideoFixture(landscape: landscape), title: "A moment to share", aspectRatio: landscape ? 16.0 / 9 : 9.0 / 16)])
                } else {
                    player.playlistSource = try await BenchmarkOptions().dataSource()
                }
                await player.start()
                model.trace.player = player
                #if DEBUG
                if BenchmarkOptions().values["social-trace"] == "1" { await model.trace.record() }
                #endif
            } catch { model.error = error.localizedDescription }
        }
        .onDisappear { player.teardown() }
    }
}

@MainActor @Observable private final class SocialLayoutModel {
    var sheetHeight: CGFloat = 0
    var dragStart: CGFloat?
    var fires = 0
    var taps = 0
    var links = 0
    var fireLocation: CGPoint?
    var error: String?
    var adPlaying = false
    let trace = SocialLayoutTrace()
    func setSheet(_ height: CGFloat, reduceMotion: Bool) {
        if reduceMotion { sheetHeight = height }
        else { withAnimation(.easeInOut(duration: 0.25)) { sheetHeight = height } }
    }
    func fire(at point: CGPoint) {
        fires += 1; fireLocation = point; trace.lastFire = point
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            if fireLocation == point { fireLocation = nil }
        }
    }
}

/// The overlay closure captures a stable model; sheet drags don't reconstruct the feed.
private struct SocialFeed: View {
    let player: HMPlayer
    let model: SocialLayoutModel
    let size: CGSize
    let safe: EdgeInsets
    private let feed: HMVerticalFeedView<SocialOverlay>
    init(player: HMPlayer, model: SocialLayoutModel, size: CGSize, safe: EdgeInsets) {
        self.player = player; self.model = model; self.size = size; self.safe = safe
        feed = HMVerticalFeedView(player: player) { item, snapshot in
            SocialOverlay(player: player, model: model, item: item, snapshot: snapshot, safe: safe)
        }
    }
    var body: some View {
        feed
            .modifier(SocialVideoLayout(sheetHeight: model.sheetHeight, size: size, safe: safe, aspect: player.snapshot.aspectRatio))
            .hmVideoGestures(isAdPlaying: model.adPlaying, accessibilityLabel: "Social video",
                onTap: { model.taps += 1; player.togglePlayPause() }, onDoubleTap: { model.fire(at: $0) })
            // Fullscreen uses its own zero-inset layout and recomputes overlay hit areas.
            .hmFullscreenVideoLayout(HMVideoLayout())
    }
}

/// Interpolate the host's sheet progress before passing rectangles to the native layer.
/// Both animated open/close and direct interactive updates therefore resize the same layer each frame.
private struct SocialVideoLayout: AnimatableModifier {
    var sheetHeight: CGFloat
    let size: CGSize
    let safe: EdgeInsets
    let aspect: Double?
    var animatableData: CGFloat {
        get { sheetHeight }
        set { sheetHeight = newValue }
    }
    func body(content: Content) -> some View {
        let nav = 78 + safe.bottom
        let space = CGRect(x: 0, y: safe.top, width: size.width, height: max(0, size.height - nav - sheetHeight - safe.top))
        let squeeze = HMVideoPresentation.fit.videoFrame(aspectRatio: aspect, in: space)
        content.hmVideoLayout(HMVideoLayout(contentInsets: HMVideoInsets(bottom: nav), squeezeTarget: sheetHeight > 0 ? squeeze : nil))
            .hmExcludedHitAreas([CGRect(x: 0, y: size.height - nav - sheetHeight, width: size.width, height: sheetHeight + nav)])
    }
}

private struct SocialChrome: View {
    let player: HMPlayer
    let model: SocialLayoutModel
    let size: CGSize
    let safe: EdgeInsets
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let nav = 78 + safe.bottom
        ZStack(alignment: .bottom) {
            if let point = model.fireLocation {
                Image(systemName: "flame.fill").font(.system(size: 60)).foregroundStyle(.orange)
                    .position(point).allowsHitTesting(false).accessibilityHidden(true)
            }
            if model.sheetHeight > 0 {
                VStack(spacing: 16) {
                    Capsule().fill(.secondary).frame(width: 48, height: 5).padding(.top, 12)
                        .accessibilityElement().accessibilityLabel("Resize comments")
                        .accessibilityIdentifier("social-sheet-handle")
                        .accessibilityAdjustableAction { direction in
                            setSheet(direction == .increment ? min(520, model.sheetHeight + 160) : max(0, model.sheetHeight - 160))
                        }
                    HStack {
                        Text("Comments").font(.headline); Spacer()
                        Button("Fullscreen") { player.enterFullscreen() }.accessibilityIdentifier("social-sheet-fullscreen")
                        Button("Close") { setSheet(0) }.accessibilityIdentifier("social-close-comments")
                    }
                    Text("@courtside  What a play! 🔥")
                    Text("@fan  Run that back.")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24).frame(height: model.sheetHeight).frame(maxWidth: .infinity)
                .background(.ultraThinMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                    if model.dragStart == nil { model.dragStart = model.sheetHeight }
                    model.sheetHeight = min(size.height - nav - safe.top - 80, max(80, (model.dragStart ?? 360) - value.translation.height))
                }.onEnded { value in
                    model.dragStart = nil
                    setSheet(value.predictedEndTranslation.height > 180 ? 0 : (model.sheetHeight > 440 ? 520 : 360))
                })
                .padding(.bottom, nav).zIndex(10)
            }
            HStack {
                Button(action: { dismiss() }) { Label("Home", systemImage: "house.fill") }.accessibilityIdentifier("social-home")
                Spacer(); Button("Ad gate") { model.adPlaying.toggle() }.accessibilityIdentifier("social-ad-gate")
                Spacer(); Label("Profile", systemImage: "person.crop.circle")
            }
            .font(.caption).padding(.horizontal, 24).padding(.bottom, safe.bottom)
            .frame(height: nav).background(.black).foregroundStyle(.white).compositingGroup().zIndex(20)
            if let error = model.error { Text(error).padding().background(.red).frame(maxHeight: .infinity, alignment: .top) }
        }
        .onChange(of: model.sheetHeight) { _, value in model.trace.sheetHeight = value }
    }
    private func setSheet(_ height: CGFloat) { model.setSheet(height, reduceMotion: reduceMotion) }
}

private struct SocialOverlay: View {
    let player: HMPlayer
    let model: SocialLayoutModel
    let item: HMMediaItem
    let snapshot: HMPlaybackSnapshot
    let safe: EdgeInsets
    @Environment(\.hmReservedRegions) private var reserved
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            let safe = player.isFullscreen ? geometry.safeAreaInsets : self.safe
            let nav: CGFloat = player.isFullscreen ? 0 : 78 + safe.bottom
            let sheetHeight: CGFloat = player.isFullscreen ? 0 : model.sheetHeight
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let sidecar = CGRect(x: geometry.size.width - 92 - safe.trailing, y: safe.top + 140, width: 76, height: 64)
            let sidecarFits = HMOverlayRegions.isFree(sidecar, videoFrame: snapshot.videoFrame, in: bounds,
                safeArea: HMVideoInsets(top: safe.top, left: safe.leading, bottom: safe.bottom, right: safe.trailing),
                contentInsets: HMVideoInsets(bottom: nav), excluding: reserved.filter { $0 != sidecar })
            ZStack(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("HOST OVERLAY").font(.headline)
                    Text("\(snapshot.state.rawValue) · taps \(model.taps) · fire \(model.fires) · links \(model.links)")
                        .accessibilityIdentifier("social-status")
                    Text("frame \(Int(snapshot.videoFrame.width))×\(Int(snapshot.videoFrame.height))")
                    Text("node \(model.trace.nodeKey) · frames \(model.trace.frames) · stalls \(model.trace.stalls)")
                        .accessibilityIdentifier("social-continuity")
                    Text("Fire at \(model.trace.lastFire.map { "\(Int($0.x)),\(Int($0.y))" } ?? "—")")
                        .accessibilityIdentifier("social-fire-location")
                    if snapshot.state == .paused { Image(systemName: "play.fill").font(.largeTitle) }
                }
                .font(.caption).padding(16).padding(.top, safe.top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).allowsHitTesting(false)
                if sheetHeight == 0 {
                    if sidecarFits {
                        Button { model.links += 1 } label: { Text("Sidecar\nAd slot").font(.caption).frame(width: 76, height: 64).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8)) }
                            .hmExcludedHitArea().position(x: sidecar.midX, y: sidecar.midY).accessibilityIdentifier("social-sidecar")
                    }
                    HMHitArea {
                        VStack(alignment: .leading, spacing: 12) {
                            Button("@courtside · Follow") { model.links += 1 }.accessibilityIdentifier("social-metadata-link")
                            Text(item.title ?? "The moment everyone is talking about")
                            Button("View all comments") { setSheet(360) }.accessibilityIdentifier("social-comment-preview")
                        }.padding(16).frame(width: max(0, geometry.size.width - 96), alignment: .leading)
                    }.padding(.bottom, nav + 12)
                    HMHitArea {
                        VStack(spacing: 24) {
                            Button { model.fire(at: CGPoint(x: geometry.size.width - 44, y: geometry.size.height / 2)) } label: { VStack { Image(systemName: "flame.fill"); Text(HMCountFormatter().string(from: 12_345 + model.fires)) } }.accessibilityIdentifier("social-fire")
                            Button { setSheet(360) } label: { Image(systemName: "bubble.right.fill") }.accessibilityIdentifier("social-comments")
                            Button("Share") { model.links += 1 }.accessibilityIdentifier("social-share")
                            Button { player.enterFullscreen() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.accessibilityIdentifier("social-fullscreen")
                        }.font(.title3).padding(12).frame(width: 76)
                    }
                    .padding(.trailing, max(8, safe.trailing)).padding(.bottom, nav + 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }.foregroundStyle(.white)
            .onChange(of: snapshot.videoFrame, initial: true) { _, frame in model.trace.videoFrame = frame }
        }
    }
    private func setSheet(_ height: CGFloat) { model.setSheet(height, reduceMotion: reduceMotion) }
}

/// Public analytics attachment exposes native layer identity without private SDK API.
@MainActor @Observable private final class SocialLayoutTrace: HMAnalyticsSink {
    let sinkName = "social-layout"
    weak var player: HMPlayer?
    var frames = 0
    var stalls = 0
    var nodeKey = "pending"
    var layerIdentity = "pending"
    private var attachments: [String: (String, String)] = [:]
    var sheetHeight: CGFloat = 0
    var videoFrame = CGRect.zero
    var lastFire: CGPoint?
    func attach(playerLayer: AVPlayerLayer, playerKey: String, item: HMMediaItem) {
        attachments[item.id] = (playerKey, String(describing: ObjectIdentifier(playerLayer)))
        nodeKey = playerKey; layerIdentity = String(describing: ObjectIdentifier(playerLayer))
    }
    func handle(_ event: HMPlaybackEvent, item: HMMediaItem) {
        if event.kind == .firstFrame { frames += 1 }
        if event.kind == .rebufferStart { stalls += 1 }
    }
    #if DEBUG
    func record() async {
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("social-layout.jsonl")
        try? Data().write(to: file)
        while !Task.isCancelled {
            if let player {
                if let id = player.currentItem?.id, let attachment = attachments[id] {
                    nodeKey = attachment.0; layerIdentity = attachment.1
                }
                let data: [String: Any] = ["time": ProcessInfo.processInfo.systemUptime, "node": nodeKey, "layer": layerIdentity,
                    "frames": frames, "stalls": stalls, "playhead": player.snapshot.currentTime, "state": player.snapshot.state.rawValue,
                    "sheetHeight": sheetHeight, "videoFrame": [videoFrame.minX, videoFrame.minY, videoFrame.width, videoFrame.height]]
                if let line = try? JSONSerialization.data(withJSONObject: data, options: .sortedKeys), let handle = try? FileHandle(forWritingTo: file) {
                    _ = try? handle.seekToEnd(); try? handle.write(contentsOf: line + Data([10])); try? handle.close()
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
    #endif
}

/// Offline generated content for the gesture demo and simulator UI test. No network or environment setup.
@MainActor func socialVideoFixture(landscape: Bool, name: String = "social-fixture", seconds: Int = 12) async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".mp4")
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let width = landscape ? 320 : 180, height = landscape ? 180 : 320
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
    guard let pixels = buffer else { throw CocoaError(.fileWriteUnknown) }
    CVPixelBufferLockBaseAddress(pixels, [])
    memset(CVPixelBufferGetBaseAddress(pixels), 80, CVPixelBufferGetDataSize(pixels))
    CVPixelBufferUnlockBaseAddress(pixels, [])
    for frame in 0..<(seconds * 10) {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        guard adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
    input.markAsFinished(); await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    return url
}
