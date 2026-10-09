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
final class HMPlayerNode: Identifiable {

    let id: String
    @ObservationIgnored let player: AVPlayer
    @ObservationIgnored let playerLayer: AVPlayerLayer

    private(set) var item: HMMediaItem?
    private(set) var snapshot = HMPlaybackSnapshot()
    /// A seek invalidates visible-frame continuity even when the layer stays ready.
    private(set) var displayRevision = 0
    @ObservationIgnored private(set) var isSeekingFrame = false

    /// Set by the pool; drives eviction order.
    @ObservationIgnored var lastTouched = Date.distantPast
    /// True once this node is the on-screen item rather than a warmed neighbour.
    @ObservationIgnored private(set) var isActive = false

    @ObservationIgnored var onEvent: ((HMPlaybackEvent, HMMediaItem) -> Void)?
    @ObservationIgnored var onBufferChanged: (() -> Void)?
    @ObservationIgnored private var durationTask: Task<Void, Never>?
    @ObservationIgnored private var summaryTask: Task<Void, Never>?
    @ObservationIgnored private var activationID = ""
    @ObservationIgnored private var activationReason = ""
    @ObservationIgnored private var stallCount10 = 0
    @ObservationIgnored private var stallTime10 = 0.0
    @ObservationIgnored private var didReportSummary = false
    @ObservationIgnored private var didPreroll = false
    @ObservationIgnored private var prerollComplete = false
    @ObservationIgnored private var wantsPlayback = false
    @ObservationIgnored private var videoOutput: AVPlayerItemVideoOutput?
    @ObservationIgnored private var startupResolutionSource = "unknown"
    @ObservationIgnored private var startupWidth = 0.0
    @ObservationIgnored private var startupHeight = 0.0
    @ObservationIgnored private var startupBitrate = 0.0
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

    /// A deferred playlist removal suppresses only this visit's loop.
    var finishesThenLeaves = false
    func updateMetadata(_ updated: HMMediaItem) {
        guard item?.hasSameMedia(as: updated) == true else { return }
        item = updated
    }
    var playbackSnapshot: HMPlaybackSnapshot {
        var value = snapshot
        if !isActive {
            value.readinessTier = !isSeekingFrame && player.currentItem?.status == .readyToPlay && playerLayer.isReadyForDisplay ? .warmPlayer : .resolved
        }
        return value
    }

    // MARK: - Content

    /// Attach `item` to this node and begin buffering, without playing.
    ///
    /// This is the preload path. Buffer target and bitrate ceiling are kept low
    /// so warming a neighbour never competes with the item on screen.
    func warm(with newItem: HMMediaItem, playbackURL: URL? = nil) {
        guard item != newItem, let mediaURL = newItem.url else { return }

        let recycledFrom = item
        finishesThenLeaves = false
        wantsPlayback = false
        player.pause()
        setLayerVisible(false)
        isActive = false
        teardownItemObservers()
        item = newItem
        displayRevision += 1; isSeekingFrame = false
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
        didPreroll = false
        prerollComplete = false
        warmStartedAt = ProcessInfo.processInfo.systemUptime

        let asset = AVURLAsset(
            url: playbackURL ?? mediaURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        let playerItem = AVPlayerItem(asset: asset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        videoOutput = output; playerItem.add(output)
        playerItem.preferredForwardBufferDuration = min(1, configuration.prefetch.warmBufferDuration)
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

    /// Only prepared neighbours may adopt a changed cap; activation sets the current cap once.
    func applyStartingBitRate(_ cap: Double) {
        if !isActive, let item = player.currentItem, item.preferredPeakBitRate != cap { item.preferredPeakBitRate = cap }
    }

    /// Only N+1's initial preroll may delay bulk work. Failed, audio-only and
    /// non-decoding assets must not block the rest of the window indefinitely.
    func isWaitingForWarmFrame(at now: TimeInterval) -> Bool {
        snapshot.state != .failed && !snapshot.isFrameReady &&
            warmStartedAt.map { now - $0 < 2 } == true
    }

    /// Promote this node to the on-screen item and begin playback.
    func activate(startingAt position: TimeInterval? = nil, requestedAt: TimeInterval = ProcessInfo.processInfo.systemUptime, reason: String = "play", cachedBytes: Int = 0) {
        guard let item else { return }
        isActive = true
        didLiftStartupCap = false
        player.currentItem?.preferredPeakBitRate = configuration.startupPeakBitRate
        activationTime = requestedAt
        activationID = UUID().uuidString; snapshot.activationID = activationID
        activationReason = reason
        hasReportedFirstFrame = false; snapshot.timeToFirstFrame = nil
        stallCount10 = 0; stallTime10 = 0; didReportSummary = false
        snapshot.stallCount = 0; snapshot.totalStallDuration = 0
        startupWidth = 0; startupHeight = 0; startupBitrate = 0; startupResolutionSource = "unknown"
        if let position, position > 0.1 {
            seekForDisplay(to: CMTime(seconds: position, preferredTimescale: 600), toleranceAfter: .positiveInfinity)
        }
        // A warmed item may have logged its rendition before activation.
        syncVariant()
        syncBufferHealth()
        let status = player.currentItem?.status.rawValue ?? 0
        let warmReady = !isSeekingFrame && status == AVPlayerItem.Status.readyToPlay.rawValue && playerLayer.isReadyForDisplay
        let budget = configuration.prefetch.bytesPerItem
        let minimum = min(max(1, configuration.minimumCachedStartBytes), budget > 0 ? budget : Int.max)
        let readiness = HMReadinessTier.atActivation(warm: warmReady, cachedBytes: cachedBytes, minimumBytes: minimum)
        let tier = readiness.rawValue
        snapshot.readinessTier = readiness
        snapshot.wasPreloaded = readiness == .warmPlayer || readiness == .cachedBytes
        snapshot.isFrameReady = !isSeekingFrame && playerLayer.isReadyForDisplay
        setLayerVisible(snapshot.isFrameReady)
        summaryTask?.cancel()
        summaryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.reportStartupSummary()
        }

        // Raising a prerolled item's target from a small head to ten seconds at
        // commit makes AVPlayer wait to minimise stalls. Keep its startup target
        // until the startup window ends, just as we keep the starting bitrate.
        if !prerollComplete { player.currentItem?.preferredForwardBufferDuration = configuration.steadyBufferDuration }

        emit(.viewStart, item: item, metrics: ["buffered_ahead_s": snapshot.bufferedAhead, "cached_bytes": Double(cachedBytes), "item_status": Double(status), "request_monotonic_s": requestedAt, "warm_started_monotonic_s": warmStartedAt ?? requestedAt, "preroll_complete": prerollComplete ? 1 : 0], properties: ["readiness_tier": tier, "transport": (player.currentItem?.asset as? AVURLAsset)?.url.host == "127.0.0.1" && (player.currentItem?.asset as? AVURLAsset)?.url != item.url ? "loopback" : "direct"])

        wantsPlayback = true
        player.play()
        emit(.play, item: item)
    }

    /// Demote to a warmed neighbour: stop playback but keep the buffer.
    func deactivate(retainingPosition: Bool) {
        guard isActive, let item else { return }
        handleStallEnded()
        reportStartupSummary()
        summaryTask?.cancel()
        isActive = false
        let watched = snapshot.currentTime
        wantsPlayback = false
        player.pause()
        if !retainingPosition {
            // Match AVPlayer.seek(to:)'s original rewind tolerances. An exact
            // seek here does unnecessary decode work just before pool recycle.
            seekForDisplay(to: .zero, toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity)
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
        summaryTask?.cancel()
        durationTask?.cancel()
        teardownItemObservers()
        setLayerVisible(false)
        player.replaceCurrentItem(with: nil)
        videoOutput = nil
        item = nil
        displayRevision += 1; isSeekingFrame = false
        isActive = false
        snapshot = HMPlaybackSnapshot()
    }

    private func setLayerVisible(_ visible: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.opacity = visible ? 1 : 0
        CATransaction.commit()
    }

    private func seekForDisplay(to time: CMTime, toleranceBefore: CMTime = .zero, toleranceAfter: CMTime = .zero, completion: (() -> Void)? = nil) {
        guard let currentItem = player.currentItem else { return }
        displayRevision += 1
        let revision = displayRevision
        isSeekingFrame = true; snapshot.isFrameReady = false; setLayerVisible(false)
        player.seek(to: time, toleranceBefore: toleranceBefore, toleranceAfter: toleranceAfter) { [weak self, weak currentItem] finished in
            Task { @MainActor [weak self] in
                guard finished, let self, let currentItem, self.player.currentItem === currentItem,
                      self.displayRevision == revision else { return }
                self.displayRevision += 1; self.isSeekingFrame = false
                self.snapshot.isFrameReady = self.playerLayer.isReadyForDisplay
                self.setLayerVisible(self.snapshot.isFrameReady)
                self.onBufferChanged?()
                completion?()
            }
        }
    }

    // MARK: - Transport

    func play() {
        guard let item else { return }
        wantsPlayback = true
        player.play()
        emit(.play, item: item)
    }

    func pause() {
        guard let item else { return }
        wantsPlayback = false
        player.pause()
        emit(.pause, item: item)
    }

    func togglePlayPause() {
        player.timeControlStatus == .paused ? play() : pause()
    }

    func setMuted(_ muted: Bool) {
        player.isMuted = muted
        snapshot.isMuted = muted
    }

    func seek(to seconds: TimeInterval) {
        guard let item, snapshot.seekableDuration > 0 else { return }
        // Map into the seekable window so this stays correct on DVR.
        let target = min(snapshot.duration, max(0, seconds))
        emit(.seeking, item: item, position: snapshot.currentTime)
        seekForDisplay(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] in
            guard let self, self.item == item else { return }
            self.emit(.seeked, item: item, position: target)
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
                now: ProcessInfo.processInfo.systemUptime
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
        durationTask?.cancel()
        durationTask = Task { [weak self] in
            guard let duration = try? await asset.load(.duration) else { return }
            let seconds = duration.seconds
            guard seconds.isFinite, seconds > 0 else { return }
            await MainActor.run {
                // The node may have been recycled while we were loading.
                guard let self, self.item?.id == itemID, !Task.isCancelled else { return }
                self.confirmDuration(seconds)
            }
        }
    }

    // MARK: - Observation

    private func installPlayerObservers() {
        observations.append(playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.snapshot.isFrameReady = !self.isSeekingFrame && self.playerLayer.isReadyForDisplay
                self.setLayerVisible(self.snapshot.isFrameReady)
                self.onBufferChanged?()
            }
        })
        observations.append(player.observe(\.status, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.syncItemStatus() }
        })
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
            handleStallEnded()
            snapshot.state = .playing
            emit(.playing, item: item)
        case .paused:
            handleStallEnded()
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
            if snapshot.state == .loading { snapshot.state = isActive ? .loading : .ready }
            if !isActive, !didPreroll, player.status == .readyToPlay, player.rate == 0 {
                // Decode the first frame without advancing the media clock.
                didPreroll = true
                player.preroll(atRate: 1) { [weak self, weak playerItem] complete in
                    Task { @MainActor in
                        guard let self, let playerItem, self.player.currentItem === playerItem else { return }
                        self.prerollComplete = complete
                        self.onBufferChanged?()
                    }
                }
            }
            emit(.preloadReady, item: item, metrics: [
                "duration_s": snapshot.duration,
                "warm_ms": warmStartedAt.map { (ProcessInfo.processInfo.systemUptime - $0) * 1000 } ?? 0
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
            .first(where: { $0.containsTime(playerItem.currentTime()) || abs($0.start.seconds - current) < 0.05 })
        snapshot.bufferedAhead = buffered.map { max(0, $0.start.seconds + $0.duration.seconds - current) } ?? 0
        onBufferChanged?()
    }

    private func syncVariant() {
        guard let item, let event = player.currentItem?.accessLog()?.events.last else { return }
        let bitrate = event.indicatedBitrate
        if isActive, startupBitrate == 0, bitrate > 0 {
            startupBitrate = bitrate

        }
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
        syncBufferHealth()
        liftStartupCapIfDue()
    }

    /// Once playback is genuinely stable, remove the startup bitrate ceiling so
    /// ABR can climb to the quality the connection can actually sustain.
    private func liftStartupCapIfDue() {
        guard !didLiftStartupCap,
              isActive,
              let activationTime,
              ProcessInfo.processInfo.systemUptime - activationTime > configuration.startupBitRateWindow
        else { return }
        didLiftStartupCap = true
        player.currentItem?.preferredPeakBitRate = configuration.steadyPeakBitRate
        player.currentItem?.preferredForwardBufferDuration = configuration.steadyBufferDuration
    }

    /// Called only by a visible surface at a display-link boundary after its
    /// layer was ready and committed. Never called by the media progress tick.
    func didDisplayFrame(activation: String, at time: TimeInterval) {
        guard isActive, activation == activationID, !hasReportedFirstFrame, !isSeekingFrame,
              playerLayer.isReadyForDisplay, player.currentItem?.status == .readyToPlay, let item, let activationTime else { return }
        hasReportedFirstFrame = true
        if let buffer = videoOutput?.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) {
            startupWidth = Double(CVPixelBufferGetWidth(buffer)); startupHeight = Double(CVPixelBufferGetHeight(buffer))
            startupResolutionSource = "decoded-pixel-buffer"
        } else {
            let size = player.currentItem?.presentationSize ?? .zero
            startupWidth = Double(size.width); startupHeight = Double(size.height)
            startupResolutionSource = "presentation-size-fallback"
        }
        if let output = videoOutput { player.currentItem?.remove(output); videoOutput = nil }
        let ttff = max(0, time - activationTime)
        snapshot.timeToFirstFrame = ttff
        emit(.firstFrame, item: item, metrics: ["ttff_ms": ttff * 1000, "preloaded": snapshot.wasPreloaded ? 1 : 0], properties: ["detector": "layer-ready+visible-display-boundary", "readiness_tier": snapshot.readinessTier.rawValue], occurredAt: time)
    }

    private func reportStartupSummary() {
        guard !didReportSummary, let item, let activationTime else { return }
        didReportSummary = true
        let now = ProcessInfo.processInfo.systemUptime
        let ongoing = stallStartedAt.map { max(0, min(now, activationTime + 10) - $0) } ?? 0
        let size = player.currentItem?.presentationSize ?? .zero
        emit(.startupSummary, item: item, metrics: ["stall_count_10s": Double(stallCount10), "stall_time_10s": stallTime10 + ongoing,
            "observed_window_s": min(10, max(0, now - activationTime)), "startup_bitrate": startupBitrate,
            "startup_width": startupWidth > 0 ? startupWidth : Double(size.width), "startup_height": startupHeight > 0 ? startupHeight : Double(size.height)], properties: ["startup_resolution_source": startupResolutionSource])
    }

    private func handleStallBegan() {
        guard isActive, hasReportedFirstFrame, stallStartedAt == nil, let item else { return }
        stallStartedAt = ProcessInfo.processInfo.systemUptime
        snapshot.state = .buffering
        snapshot.stallCount += 1
        if let activationTime, ProcessInfo.processInfo.systemUptime - activationTime < 10 { stallCount10 += 1 }
        emit(.rebufferStart, item: item, position: snapshot.currentTime)
    }

    private func handleStallEnded() {
        guard let started = stallStartedAt, let item else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        stallStartedAt = nil
        if let activationTime { stallTime10 += max(0, min(ProcessInfo.processInfo.systemUptime, activationTime + 10) - max(started, activationTime)) }
        snapshot.totalStallDuration += elapsed
        emit(.rebufferEnd, item: item, position: snapshot.currentTime, metrics: ["stall_ms": elapsed * 1000])
    }

    private func handleReachedEnd() {
        guard let item else { return }
        handleStallEnded()
        let shouldLoop = configuration.loops && !finishesThenLeaves
        emit(.ended, item: item, position: snapshot.currentTime)
        if shouldLoop, self.item?.hasSameMedia(as: item) == true {
            seekForDisplay(to: .zero)
            if isActive && wantsPlayback { player.play() }
        }
    }

    private func handleFailure(_ error: NSError?) {
        guard let item, snapshot.state != .failed else { return }
        if let mediaURL = item.url, let asset = player.currentItem?.asset as? AVURLAsset, asset.url.host == "127.0.0.1", asset.url != item.url {
            // A dead listener or host ATS policy must not strand playback. The
            // direct retry keeps this activation and its original request clock.
            let position = snapshot.currentTime
            let resume = isActive && wantsPlayback
            teardownItemObservers(); setLayerVisible(false)
            let asset = AVURLAsset(url: mediaURL)
            let replacement = AVPlayerItem(asset: asset)
            replacement.preferredPeakBitRate = didLiftStartupCap ? configuration.steadyPeakBitRate : configuration.startupPeakBitRate
            replacement.preferredForwardBufferDuration = isActive ? configuration.steadyBufferDuration : configuration.prefetch.warmBufferDuration
            installItemObservers(for: replacement); player.replaceCurrentItem(with: replacement)
            videoOutput = nil; didPreroll = false; prerollComplete = false; snapshot.state = .loading
            displayRevision += 1; isSeekingFrame = false; snapshot.isFrameReady = false
            loadDuration(from: asset, for: item.id)
            if position > 0 { seekForDisplay(to: CMTime(seconds: position, preferredTimescale: 600)) }
            emit(.loadStart, item: item, metrics: ["proxy_fallback": 1], properties: ["transport": "direct-fallback",
                "error_domain": error?.domain ?? "unknown", "error_code": String(error?.code ?? -1),
                "error_message": error?.localizedDescription ?? "Playback failed"])
            if resume { player.play() }
            return
        }
        handleStallEnded()
        snapshot.state = .failed
        snapshot.errorDescription = error?.localizedDescription ?? "Playback failed"
        emit(.error, item: item, properties: [
            "transient_network": String(HMNetworkFailure.isTransient(error)),
            "error_code": String(error?.code ?? -1),
            "error_domain": error?.domain ?? "unknown",
            "error_log": player.currentItem?.errorLog()?.events.last?.errorComment ?? "",
            "error_message": snapshot.errorDescription ?? ""
        ])
    }

    // MARK: - Emission

    private func emit(
        _ kind: HMPlaybackEvent.Kind,
        item: HMMediaItem,
        position: TimeInterval? = nil,
        metrics: [String: Double] = [:],
        properties: [String: String] = [:],
        occurredAt: TimeInterval? = nil
    ) {
        var props = properties
        props["player_key"] = id
        if isActive || kind == .viewEnd { props["activation_id"] = activationID; props["activation_reason"] = activationReason }
        onEvent?(
            HMPlaybackEvent(
                kind: kind,
                itemID: item.id,
                monotonicTime: occurredAt ?? ProcessInfo.processInfo.systemUptime,
                position: position ?? snapshot.currentTime,
                metrics: metrics,
                properties: props
            ),
            item
        )
    }
}
#endif
