#if canImport(UIKit) && !os(watchOS)
import AVFoundation
import SwiftUI

/// The flagship surface: a full-bleed, snap-paging vertical feed.
///
/// Built on SwiftUI's paging scroll target rather than a `UIPageViewController`
/// so the whole thing stays a few hundred lines. Cells are lazy, and video is
/// only ever rendered by a pooled node — a cell with no node assigned shows its
/// poster, which is exactly what you want for items outside the warm window.
public struct HMVerticalFeedView<Overlay: View>: View {

    private let controller: HMPlayer
    private let transition: HMPageTransition
    private let gravity: AVLayerVideoGravity
    private let overlay: (HMMediaItem, HMPlaybackSnapshot) -> Overlay

    @State private var scrollReference = HMScrollViewReference()
    @State private var fallbackCommit: Task<Void, Never>?
    @State private var scrolledID: HMMediaItem.ID?

    /// Creates a vertical VOD feed with a partner overlay for each entry and snapshot.
    public init(
        player: HMPlayer,
        transition: HMPageTransition = .none,
        gravity: AVLayerVideoGravity = .resizeAspectFill,
        @ViewBuilder overlay: @escaping (HMMediaItem, HMPlaybackSnapshot) -> Overlay
    ) {
        self.controller = player
        self.transition = transition
        self.gravity = gravity
        self.overlay = overlay
    }

    /// Renders the vertical feed and its overlays.
    public var body: some View {
        // Outer reader still sits inside the safe area, so it can measure the
        // insets; the inner one is expanded to full bleed. Overlays read the
        // captured insets back out of the environment.
        GeometryReader { container in
            let insets = container.safeAreaInsets

            GeometryReader { proxy in
                let pageHeight = proxy.size.height
                let itemIDs = controller.items.map(\.id)
                let currentID = controller.currentItem?.id

                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(controller.items) { item in
                            cell(for: item, pageHeight: pageHeight)
                                .frame(width: proxy.size.width, height: pageHeight)
                                .id(item.id)
                        }
                        if controller.isLoadingPage {
                            loadingFooter.frame(width: proxy.size.width, height: 80)
                        }
                    }
                    .scrollTargetLayout()
                    .background(HMPageCommitProbe(itemIDs: itemIDs, currentID: controller.currentItem?.id, targetIndex: controller.requestedPageIndex, requestID: controller.pageRequestID, reference: scrollReference, interaction: { controller.setPageMoving($0) }) { id, time in
                        fallbackCommit?.cancel()
                        controller.commitPage(toID: id, requestedAt: time)
                    })
                }
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.hidden)
                .scrollPosition(id: $scrolledID)
                .background(.black)
                .onChange(of: scrolledID) { _, id in
                    fallbackCommit?.cancel()
                    guard let id, let index = controller.items.firstIndex(where: { $0.id == id }), index != controller.activeIndex else { return }
                    fallbackCommit = Task { @MainActor in
                        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                        guard controller.currentItem?.id == currentID, HMPagePosition.survives(old: itemIDs, new: controller.items.map(\.id), current: currentID, destination: id), scrolledID == id, let index = controller.items.firstIndex(where: { $0.id == id }), index != controller.activeIndex else { return }
                        let now = ProcessInfo.processInfo.systemUptime
                        if let scroll = scrollReference.scroll {
                            guard !scroll.isDragging, !scroll.isDecelerating, now - scrollReference.lastMotionAt >= 0.2 else { return }
                        }
                        controller.commitPage(toID: id, requestedAt: scrollReference.lastMotionAt > 0 ? scrollReference.lastMotionAt : now)
                    }
                }
                .onAppear { controller.attachFeed() }
                .onDisappear { fallbackCommit?.cancel(); controller.detachFeed() }
                .onChange(of: controller.currentItem?.id) { _, id in
                    fallbackCommit?.cancel()
                    if id != scrolledID { scrolledID = id }
                }
                .task {
                    await controller.start()
                    scrolledID = controller.currentItem?.id
                }
            }
            .ignoresSafeArea()
            .environment(\.hmFeedSafeArea, insets)
        }
        .background(.black)
    }

    @ViewBuilder
    private func cell(for item: HMMediaItem, pageHeight: Double) -> some View {
        let node = controller.node(for: item)
        let snapshot = controller.snapshot(for: item)
        let displayItem = controller.displayItem(item)

        ZStack {
            Color.black

            if let posterURL = displayItem.posterURL {
                // Poster stays underneath so the first frame cross-dissolves in
                // rather than punching through black.
                HMPosterView(url: posterURL)
            }

            HMVideoSurface(node: node, gravity: gravity)


            overlay(displayItem, snapshot)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .contentShape(.rect)
        .modifier(PageTransitionEffect(transition: transition, pageHeight: pageHeight))
    }

    private var loadingFooter: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .tint(.white)
    }
}

/// Applies the page transition, and gets out of the way entirely when there
/// isn't one — an identity `rotation3DEffect` still forces a 3D transform layer
/// on every cell, which is pure cost in the default configuration.
private struct PageTransitionEffect: ViewModifier {
    let transition: HMPageTransition
    let pageHeight: Double

    func body(content: Content) -> some View {
        if transition == .none {
            content
        } else {
            content.visualEffect { view, geometry in
                let frame = geometry.frame(in: .scrollView(axis: .vertical))
                let centreOffset = pageHeight > 0 ? (frame.minY / pageHeight) : 0
                let attributes = transition.attributes(offset: centreOffset, height: pageHeight)
                return view
                    .opacity(attributes.opacity)
                    .scaleEffect(attributes.scale)
                    .offset(y: attributes.offsetY)
                    .rotation3DEffect(
                        .degrees(attributes.rotationDegrees),
                        axis: (x: 1, y: 0, z: 0),
                        anchor: attributes.anchor,
                        perspective: attributes.perspective
                    )
            }
        }
    }
}

public extension HMVerticalFeedView where Overlay == EmptyView {
    /// Creates a vertical feed without an overlay.
    init(
        player: HMPlayer,
        transition: HMPageTransition = .none,
        gravity: AVLayerVideoGravity = .resizeAspectFill
    ) {
        self.init(player: player, transition: transition, gravity: gravity) { _, _ in EmptyView() }
    }
}

/// Minimal async poster loader. Kept in-SDK on purpose: the whole point of this
/// package is that it pulls in nothing but AVFoundation and SwiftUI.
struct HMPosterView: View {
    let url: URL

    var body: some View {
        // The `Color.clear` base is load-bearing: a bare `scaledToFill` image
        // reports a huge ideal size, which would grow the enclosing cell and
        // push overlay chrome outside the visible bounds. Layering it into an
        // overlay keeps sizing driven by the cell instead of the artwork.
        Color.clear
            .overlay {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Color.black
                    }
                }
            }
            .clipped()
            .allowsHitTesting(false)
    }
}
#endif
