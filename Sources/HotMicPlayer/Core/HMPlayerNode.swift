#if canImport(AVFoundation) && !os(macOS)
import AVFoundation
import Foundation
import Observation
import QuartzCore

/// One recycled playback engine: an `AVPlayer` plus the `AVPlayerLayer` that
/// renders it.
///
/// Nodes are expensive (a decoder session each) so the feed keeps a small pool
/// of them and moves them between cells. The layer travels with the node, which
/// keeps beacon-style analytics SDKs attached across a recycle.
@MainActor
@Observable
public final class HMPlayerNode: Identifiable {

    public let id: String
    @ObservationIgnored public let player: AVPlayer
    @ObservationIgnored public let playerLayer: AVPlayerLayer

    public private(set) var item: HMMediaItem?
    public private(set) var snapshot = HMPlaybackSnapshot()

    /// Set by the pool; drives eviction order.
    @ObservationIgnored var lastTouched = Date.distantPast
    /// True once this node is the on-screen item rather than a warmed neighbour.
    @ObservationIgnored public private(set) var isActive = false

    @ObservationIgnored var onEvent: ((HMPlaybackEvent, HMMediaItem) -> Void)?
    @ObservationIgnored var configuration: HMPlayerConfiguration

    // Observation plumbing
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var timeObserver: Any?

    // Metric bookkeeping
    @ObservationIgnored private var activationTime: CFTimeInterval?
    @ObservationIgnored private var stallStartedAt: CFTimeInterval?
    @ObservationIgnored private var hasReportedFirstFrame = false
    @ObservationIgnored private var warmStartedAt: CFTimeInterval?
    @ObservationIgnored private var didLiftStartupCap = false
    @ObservationIgnored private var lastReportedVariant: Double = 0
    /// True once a real duration came from the asset or the player, as opposed
    /// to the feed API's hint. Guards against a slow async load being clobbered
    /// by the fallback.
    @ObservationIgnored private var hasConfirmedDuration = false
    @ObservationIgnored private var liveWindow = HMLiveWindowTracker()

    init(id: String, configuration: HMPlayerConfiguration) {
        self.id = id
        self.configuration = configuration
        let player = AVPlayer()
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .none
        player.isMuted = configuration.startsMuted
        self.player = player

        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.needsDisplayOnBoundsChange = true
        self.playerLayer = layer

        installPlayerObservers()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    }

    // MARK: - Content

    /// Attach `item` to this node and begin buffering, without playing.
    ///
    /// This is the preload path. Buffer target and bitrate ceiling are kept low
    /// so warming a neighbour never competes with the item on screen.
    func warm(with newItem: HMMediaItem) {
        guard item?.id != newItem.id else { return }

        let recycledFrom = item
        teardownItemObservers()
        item = newItem
        snapshot = HMPlaybackSnapshot()
        snapshot.isMuted = player.isMuted
        snapshot.state = .loading
        hasReportedFirstFrame = false
        didLiftStartupCap = false
        activationTime = nil
        stallStartedAt = nil
        lastReportedVariant = 0
        hasConfirmedDuration = false
        liveWindow.reset()
        warmStartedAt = CACurrentMediaTime()

        let asset = AVURLAsset(
            url: newItem.url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = configuration.prefetch.warmBufferDuration
        if configuration.startupPeakBitRate > 0 {
            playerItem.preferredPeakBitRate = configuration.startupPeakBitRate
        }
        installItemObservers(for: playerItem)
        player.replaceCurrentItem(with: playerItem)
        loadDuration(from: asset, for: newItem.id)

        if let recycledFrom {
            emit(.playerRecycled, item: newItem, properties: ["from_item": recycledFrom.id])
        }
        emit(.loadStart, item: newItem)
        emit(.preloadStart, item: newItem)
    }

    /// Promote this node to the on-screen item and begin playback.
    func activate(startingAt position: TimeInterval? = nil) {
        guard let item else { return }
        isActive = true
        activationTime = CACurrentMediaTime()
        snapshot.wasPreloaded = warmStartedAt.map { CACurrentMediaTime() - $0 > 0.25 } ?? false

        player.currentItem?.preferredForwardBufferDuration = configuration.steadyBufferDuration

        emit(.viewStart, item: item, properties: ["preloaded": snapshot.wasPreloaded ? "1" : "0"])

        if let position, position > 0.1 {
            player.seek(to: CMTime(seconds: position, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
        }
        player.play()
        emit(.play, item: item)
    }

    /// Demote to a warmed neighbour: stop playback but keep the buffer.
    func deactivate(retainingPosition: Bool) {
        guard isActive, let item else { return }
        isActive = false
        let watched = snapshot.currentTime
        player.pause()
        if !retainingPosition {
            player.seek(to: .zero)
            snapshot.currentTime = 0
        }
        player.currentItem?.preferredForwardBufferDuration = configuration.prefetch.warmBufferDuration
        snapshot.state = .ready
        emit(.viewEnd, item: item, metrics: [
            "watch_time_s": watched,
            "stall_count": Double(snapshot.stallCount),
            "stall_time_s": snapshot.totalStallDuration
        ])
    }

    /// Detach content entirely and free the decoder.
    func release() {
        if isActive { deactivate(retainingPosition: false) }
        teardownItemObservers()
        player.replaceCurrentItem(with: nil)
        item = nil
        isActive = false
        snapshot = HMPlaybackSnapshot()
    }

    // MARK: - Transport

    public func play() {
        guard let item else { return }
        player.play()
        emit(.play, item: item)
    }

    public func pause() {
        guard let item else { return }
        player.pause()
        emit(.pause, item: item)
    }

    public func togglePlayPause() {
        player.timeControlStatus == .paused ? play() : pause()
    }

    public func setMuted(_ muted: Bool) {
        player.isMuted = muted
        snapshot.isMuted = muted
    }

    public func seek(toProgress progress: Double) {
        guard let item, snapshot.seekableDuration > 0 else { return }
        // Map into the seekable window so this stays correct on DVR.
        let target = snapshot.seekableStart + snapshot.seekableDuration * min(1, max(0, progress))
        emit(.seeking, item: item, position: snapshot.currentTime)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let item = self.item else { return }
                self.emit(.seeked, item: item, position: target)
            }
        }
        snapshot.currentTime = target
    }

    private func confirmDuration(_ seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else { return }
        hasConfirmedDuration = true
        snapshot.duration = seconds
    }

    /// For HLS the seekable range is the authoritative extent, and it works for
    /// DVR windows too — unlike `duration`, which stays indefinite on live.
    ///
    /// On a live stream the window slides, so this runs on every tick rather
    /// than once.
    private func syncSeekableRange() {
        guard let playerItem = player.currentItem,
              let range = playerItem.seekableTimeRanges.last?.timeRangeValue,
              range.start.seconds.isFinite, range.duration.seconds.isFinite
        else { return }

        let isLive = !playerItem.duration.seconds.isFinite
        snapshot.isLive = isLive

        let measuredEdge = range.start.seconds + range.duration.seconds

        if isLive {
            // Smoothed, or the playhead sawtooths backwards every time the
            // manifest refreshes. See HMLiveWindowTracker.
            let window = liveWindow.update(
                measuredStart: range.start.seconds,
                measuredEdge: measuredEdge,
                now: CACurrentMediaTime()
            )
            snapshot.seekableStart = window.start
            snapshot.duration = window.edge
            hasConfirmedDuration = true
        } else if !hasConfirmedDuration {
            confirmDuration(measuredEdge)
        }
    }

    /// `AVPlayerItem.duration` is frequently still indeterminate when `status`
    /// flips to `.readyToPlay` on HLS, and it is not reliably KVO-observable
    /// afterwards. Asking the asset is the authoritative path.
    private func loadDuration(from asset: AVURLAsset, for itemID: String) {
        Task { [weak self] in
            guard let duration = try? await asset.load(.duration) else { return }
            let seconds = duration.seconds
            guard seconds.isFinite, seconds > 0 else { return }
            await MainActor.run {
                // The node may have been recycled while we were loading.
                guard let self, self.item?.id == itemID else { return }
                self.confirmDuration(seconds)
            }
        }
    }

    // MARK: - Observation

    private func installPlayerObservers() {
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.syncTimeControlStatus() }
        })
    }

    private func installItemObservers(for playerItem: AVPlayerItem) {
        observations.append(playerItem.observe(\.status, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.syncItemStatus() }
        })
        observations.append(playerItem.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.syncBufferHealth() }
        })
        observations.append(playerItem.observe(\.loadedTimeRanges, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.syncBufferHealth() }
        })

        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: playerItem, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleReachedEnd() }
        })
        notificationTokens.append(center.addObserver(
            forName: AVPlayerItem.playbackStalledNotification, object: playerItem, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleStallBegan() }
        })
        notificationTokens.append(center.addObserver(
            forName: AVPlayerItem.newAccessLogEntryNotification, object: playerItem, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncVariant() }
        })
        notificationTokens.append(center.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: playerItem, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                self?.handleFailure(error)
            }
        }) 

        if timeObserver == nil {
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
                queue: .main
            ) { [weak self] time in
                MainActor.assumeIsolated { self?.handleTick(time) }
            }
        }
    }

    private func teardownItemObservers() {
        // Keep the player-level observation, drop everything item-scoped.
        observations.removeAll()
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        notificationTokens.removeAll()
        installPlayerObservers()
    }

    // MARK: - State sync
    //
    // Handlers deliberately re-read live state rather than trusting the KVO
    // payload: observations hop to the main actor, so a stale change value
    // could otherwise be applied out of order.

    private func syncTimeControlStatus() {
        guard let item else { return }
        switch player.timeControlStatus {
        case .playing:
            if snapshot.state == .buffering { handleStallEnded() }
            snapshot.state = .playing
            emit(.playing, item: item)
            reportFirstFrameIfNeeded()
        case .paused:
            if snapshot.state != .failed && snapshot.state != .idle {
                snapshot.state = isActive ? .paused : .ready
            }
        case .waitingToPlayAtSpecifiedRate:
            // Only an empty buffer is a rebuffer. The player also parks here
            // while evaluating throughput or waiting on a seek, and counting
            // those inflates the stall metric on healthy playback.
            let isStarved = player.reasonForWaitingToPlay == .toMinimizeStalls
            if isActive, hasReportedFirstFrame, isStarved { handleStallBegan() }
        @unknown default:
            break
        }
    }

    private func syncItemStatus() {
        guard let playerItem = player.currentItem, let item else { return }
        switch playerItem.status {
        case .readyToPlay:
            let duration = playerItem.duration.seconds
            if duration.isFinite, duration > 0 {
                confirmDuration(duration)
            } else if let hint = item.durationHint, !hasConfirmedDuration {
                // Provisional only — the scrubber needs *some* scale to draw.
                snapshot.duration = hint
            }
            if snapshot.state == .loading { snapshot.state = isActive ? .playing : .ready }
            emit(.preloadReady, item: item, metrics: [
                "duration_s": snapshot.duration,
                "warm_ms": warmStartedAt.map { (CACurrentMediaTime() - $0) * 1000 } ?? 0
            ])
        case .failed:
            handleFailure(playerItem.error as NSError?)
        default:
            break
        }
    }

    private func syncBufferHealth() {
        guard let playerItem = player.currentItem else { return }
        let current = playerItem.currentTime().seconds
        let buffered = playerItem.loadedTimeRanges
            .map { $0.timeRangeValue }
            .first(where: { $0.containsTime(playerItem.currentTime()) || $0.start.seconds >= current })
        if let buffered {
            snapshot.bufferedAhead = max(0, (buffered.start.seconds + buffered.duration.seconds) - current)
        }
        if playerItem.isPlaybackLikelyToKeepUp, snapshot.state == .buffering {
            handleStallEnded()
        }
    }

    private func syncVariant() {
        guard let item, let event = player.currentItem?.accessLog()?.events.last else { return }
        let bitrate = event.indicatedBitrate
        guard bitrate > 0, bitrate != lastReportedVariant else { return }
        lastReportedVariant = bitrate
        snapshot.indicatedBitrate = bitrate
        emit(.variantChanged, item: item, metrics: [
            "indicated_bitrate": bitrate,
            "observed_bitrate": event.observedBitrate
        ], properties: ["uri": event.uri ?? ""])
    }

    private func handleTick(_ time: CMTime) {
        guard player.currentItem != nil else { return }
        snapshot.currentTime = time.seconds.isFinite ? time.seconds : 0
        // `seekableTimeRanges` allocates on every read. VOD only needs it until
        // the duration is known; a sliding live window needs it continuously.
        if !hasConfirmedDuration || snapshot.isLive { syncSeekableRange() }
        if snapshot.state == .playing { reportFirstFrameIfNeeded() }
        liftStartupCapIfDue()
    }

    /// Once playback is genuinely stable, remove the startup bitrate ceiling so
    /// ABR can climb to the quality the connection can actually sustain.
    private func liftStartupCapIfDue() {
        guard !didLiftStartupCap,
              configuration.startupPeakBitRate > 0,
              isActive,
              let activationTime,
              CACurrentMediaTime() - activationTime > configuration.startupBitRateWindow
        else { return }
        didLiftStartupCap = true
        player.currentItem?.preferredPeakBitRate = configuration.steadyPeakBitRate
    }

    private func reportFirstFrameIfNeeded() {
        guard !hasReportedFirstFrame, let item,
              player.timeControlStatus == .playing,
              snapshot.currentTime > 0
        else { return }
        hasReportedFirstFrame = true
        let ttff = activationTime.map { CACurrentMediaTime() - $0 }
        snapshot.timeToFirstFrame = ttff
        emit(.firstFrame, item: item, metrics: [
            "ttff_ms": (ttff ?? 0) * 1000,
            "preloaded": snapshot.wasPreloaded ? 1 : 0
        ])
    }

    private func handleStallBegan() {
        guard isActive, stallStartedAt == nil, let item else { return }
        stallStartedAt = CACurrentMediaTime()
        snapshot.state = .buffering
        snapshot.stallCount += 1
        emit(.rebufferStart, item: item, position: snapshot.currentTime)
    }

    private func handleStallEnded() {
        guard let started = stallStartedAt, let item else { return }
        let elapsed = CACurrentMediaTime() - started
        stallStartedAt = nil
        snapshot.totalStallDuration += elapsed
        emit(.rebufferEnd, item: item, position: snapshot.currentTime, metrics: ["stall_ms": elapsed * 1000])
    }

    private func handleReachedEnd() {
        guard let item else { return }
        emit(.ended, item: item, position: snapshot.currentTime)
        if configuration.loops {
            player.seek(to: .zero)
            if isActive { player.play() }
        }
    }

    private func handleFailure(_ error: NSError?) {
        guard let item else { return }
        snapshot.state = .failed
        snapshot.errorDescription = error?.localizedDescription ?? "Playback failed"
        emit(.error, item: item, properties: [
            "error_code": String(error?.code ?? -1),
            "error_message": snapshot.errorDescription ?? ""
        ])
    }

    // MARK: - Emission

    private func emit(
        _ kind: HMPlaybackEvent.Kind,
        item: HMMediaItem,
        position: TimeInterval? = nil,
        metrics: [String: Double] = [:],
        properties: [String: String] = [:]
    ) {
        var props = properties
        props["player_key"] = id
        onEvent?(
            HMPlaybackEvent(
                kind: kind,
                itemID: item.id,
                position: position ?? snapshot.currentTime,
                metrics: metrics,
                properties: props
            ),
            item
        )
    }
}
#endif
