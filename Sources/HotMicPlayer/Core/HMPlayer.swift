#if canImport(AVFoundation) && !os(macOS)
import AVFoundation
import Foundation
import Observation
import MediaAccessibility
#if os(iOS)
import UIKit
#endif

/// The partner SDK entry point. Owns a VOD playlist, playback, prefetch and events.
/// All mutations are synchronous and atomic on the main actor. During a swipe,
/// edits preserve a swipe unless the current or destination ID changes position.
///
/// Access on the main actor.
@MainActor @Observable public final class HMPlayer {
    /// Optional host ad decision adapter. Set before loading the playlist.
    @ObservationIgnored public var adBreakProvider: (any HMAdBreakProvider)?
    /// Host UI should hide comment affordances and squeezeback while isActive.
    public private(set) var adState: HMAdState = .none
    /// Media-time progress, observed independently without lifecycle events or analytics ticks.
    public private(set) var adProgress = HMAdProgress()
    private var adContentOutcome: HMAdOutcome?
    private var adLastProgressAt: TimeInterval = 0
    @ObservationIgnored private var adWatchdogTask: Task<Void, Never>?
    /// Feed paging policy while a break is loading or playing.
    public var isAdSwipeBlocked: Bool { adState.isActive && !configuration.allowsSwipeDuringAds }
    private var adVisit: HMMediaItem.MediaIdentity?
    private var adToken = UUID()
    private var adItem: HMMediaItem?
    private var adDecisionPending = false
    private var adDidStart = false
    private var hostBreak: HMHostAdBreak?
    private(set) var hostAdContext: HMHostAdContext?
    private(set) var adNode: HMPlayerNode?
    @ObservationIgnored private var adDecisionTask: Task<Void, Never>?
    @ObservationIgnored private var adTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var adProgressTask: Task<Void, Never>?

    /// Host-reported Picture in Picture state. The SDK owns no Picture in Picture controller; set
    /// this from your `AVPictureInPictureControllerDelegate`.
    public var isPictureInPictureActive = false {
        didSet { if isPictureInPictureActive != oldValue { emitExternalPresentation() } }
    }
    /// True while current content plays on an external route such as AirPlay.
    public private(set) var isExternalPlaybackActive = false
    /// True while companion ads must not appear: Picture in Picture or external playback is active.
    public var suppressesCompanionAds: Bool { isPictureInPictureActive || isExternalPlaybackActive }
    /// Replaces the detected external-playback state, for labs and demos without an external display.
    /// Nil follows the current content engine.
    @_spi(Benchmark) public var externalPlaybackOverride: Bool? {
        didSet { syncExternalPlayback() }
    }

    /// Nil follows the system Closed Captions + SDH preference; assigning captionsEnabled overrides it.
    public var captionPreference: Bool? { didSet { updateCaptions() } }
    /// Effective caption preference, retained across playlist changes and swipes.
    public var captionsEnabled: Bool {
        get { captionPreference ?? systemCaptionsEnabled }
        set { captionPreference = newValue }
    }
    private var systemCaptionsEnabled = MACaptionAppearanceGetDisplayType(.user) == .alwaysOn
    /// BCP-47 languages from current HLS legible tracks and MP4 sidecars. May grow when HLS metadata loads.
    public var availableCaptionLanguages: [String] { currentNode?.captions.languages ?? [] }
    /// Requested language, retained across swipes. Nil uses the system's preferred caption language.
    public private(set) var selectedCaptionLanguage: String?
    /// Selects a language and enables captions; nil returns language choice to the system.
    public func selectCaption(_ language: String?) { selectedCaptionLanguage = language; captionsEnabled = true }
    @ObservationIgnored private var captionObserver: HMCaptionSettingsObserver?
    private(set) var captionStyleRevision = 0
    private func updateCaptions() {
        for node in pool.nodes { node.captions.configure(enabled: captionsEnabled, language: selectedCaptionLanguage) }
        emit(.captionsChanged(enabled: captionsEnabled, language: selectedCaptionLanguage))
        prefetchCaptions()
    }
    private func prefetchCaptions() {
        guard isFeedVisible, captionsEnabled else { return }
        for item in items.dropFirst(activeIndex).prefix(configuration.prefetch.ahead > 0 ? 2 : 1) {
            if let language = HMCaptionController.matchLanguage(in: item.captionSources.keys.sorted(), preferences: HMCaptionController.preferences(selectedCaptionLanguage)),
               let url = item.captionSources[language] {
                Task { _ = await HMCaptionCache.shared.cues(for: url, prefetch: true) }
            }
        }
    }
    #if os(iOS)
    @ObservationIgnored private var audioObserver: HMAudioObserver?
    /// Number of SDK audio-session configurations in this process, for ownership diagnostics.
    @_spi(Benchmark) public var audioSessionConfigurationCount: Int { HMAudioSession.configurationCount }
    private var audioInterrupted = false
    private var appBackgrounded = false
    private var resumeAfterInterruption = false
    private var audioBlocked: Bool { audioInterrupted || (appBackgrounded && !configuration.allowsBackgroundAudio) }
    func handleAudioNotification(_ note: Notification) {
        guard !ended else { return }
        switch note.name {
        case AVAudioSession.interruptionNotification:
            guard let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                let reason = (note.userInfo?[AVAudioSessionInterruptionReasonKey] as? NSNumber)?.uintValue
                let suspended = (note.userInfo?[AVAudioSessionInterruptionWasSuspendedKey] as? NSNumber)?.boolValue == true
                guard reason != AVAudioSession.InterruptionReason.appWasSuspended.rawValue, !suspended else { return }
                if !audioInterrupted { resumeAfterInterruption = wantsPlayback }
                audioInterrupted = true; pauseAll(); updateHostPlaybackPermission()
                emit(.audioSession(.interruptionBegan))
            } else {
                let options = AVAudioSession.InterruptionOptions(rawValue: (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0)
                let shouldResume = options.contains(.shouldResume)
                guard audioInterrupted else {
                    emit(.audioSession(.interruptionEnded(shouldResume: shouldResume, resumed: false))); return
                }
                let eligible = resumeAfterInterruption && shouldResume && wantsPlayback
                audioInterrupted = false; resumeAfterInterruption = false
                if !shouldResume { wantsPlayback = false }
                let resumed = eligible && isFeedVisible && !audioBlocked
                if resumed { activateAudioIfManaged(); resumeActive() }
                updateHostPlaybackPermission()
                if mediaProgressAllowed { refreshWindow() }
                emit(.audioSession(.interruptionEnded(shouldResume: shouldResume, resumed: resumed)))
            }
        case AVAudioSession.routeChangeNotification:
            let raw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue ?? 0
            if raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { pause() }
            emit(.audioSession(.routeChanged(reason: raw)))
        case UIApplication.didEnterBackgroundNotification:
            guard !appBackgrounded else { return }
            appBackgrounded = true
            diagnosticsRecorder?.suspend()
            if !configuration.allowsBackgroundAudio { pauseAll() }
            updateHostPlaybackPermission(); emit(.audioSession(.enteredBackground))
        case UIApplication.didBecomeActiveNotification:
            // Latest explicit host intent also includes play/navigation while blocked.
            let eligible = wantsPlayback
            appBackgrounded = false; audioInterrupted = false
            if isFeedVisible { diagnosticsRecorder?.resume() }
            resumeAfterInterruption = false
            let resumed = eligible && isFeedVisible && !audioBlocked
            if resumed { activateAudioIfManaged(); resumeActive() }
            updateHostPlaybackPermission()
            if mediaProgressAllowed { refreshWindow() }
            emit(.audioSession(.enteredForeground(resumed: resumed)))
        case AVAudioSession.mediaServicesWereResetNotification:
            let resume = wantsPlayback
            pauseAll()
            // Rebuild AVPlayerItems, preserving the current playhead and preferences.
            if let item = currentItem { resumePositions[identity(item)] = snapshot.currentTime }
            let position = snapshot.currentTime
            mediaResetPosition = currentItem.flatMap { item in
                position.isFinite && position > 0 ? (identity(item), position) : nil
            }
            if adState.isActive { endAd(.failed, resume: false) }
            for node in pool.nodes { analytics.detach(playerKey: node.id) }
            pool.rebuild()
            activateAudioIfManaged()
            if !resume { wantsPlayback = false }
            refreshWindow()
            emit(.audioSession(.mediaServicesReset))
        default: break
        }
    }
    #else
    private var appBackgrounded: Bool { false }
    private var audioBlocked: Bool { false }
    #endif
    @ObservationIgnored private var didActivateAudioSession = false
    private var playbackAllowed: Bool { wantsPlayback && !audioBlocked }
    // Transport may serve a paused seek, but never bypass host visibility/audio policy.
    var mediaProgressAllowed: Bool { !ended && isFeedVisible && !audioBlocked }
    private func activateAudioIfManaged() {
        guard !ended, currentItem != nil else { return }
        if configuration.managesAudioSession && !audioBlocked {
            HMAudioSession.activatePlayback(); didActivateAudioSession = true
        }
    }

    private var playlist = HMPlaylistState()
    /// Loaded playlist entries, in display order.
    ///
    /// Access on the main actor.
    public var items: [HMMediaItem] { playlist.items }
    /// Index of the last committed current item; zero while idle.
    ///
    /// Access on the main actor.
    public var activeIndex: Int { currentItem == nil ? 0 : playlist.index }
    /// Index of the current entry, or nil when empty or idle after failures.
    ///
    /// Access on the main actor.
    public var currentIndex: Int? { currentItem == nil ? nil : playlist.index }
    /// Last committed current entry, or nil while idle.
    ///
    /// Access on the main actor.
    public var currentItem: HMMediaItem? { failureIdle ? nil : playlist.current }
    /// Fullscreen changes rendering ownership only; it never activates or seeks the node.
    public private(set) var isFullscreen = false
    /// Enters fullscreen for the active item, canceling any pending page request. Access on the main actor.
    public func enterFullscreen() {
        guard !ended, currentItem != nil else { return }
        requestedPageID = nil
        isFullscreen = true
    }
    /// Returns to the same inline item and feed page. Access on the main actor.
    public func exitFullscreen() {
        guard isFullscreen else { return }
        isFullscreen = false
        scheduleFailedItemAdvance()
    }
    // A single mounted presenter owns fullscreen for this engine. A duplicate is inert.
    @ObservationIgnored weak var fullscreenPresenter: AnyObject?
    @ObservationIgnored private var inlineSurfaces = 0
    func attachInline() { inlineSurfaces += 1; isFeedVisible = true }
    func detachInline() {
        inlineSurfaces = max(0, inlineSurfaces - 1)
        if inlineSurfaces == 0, feedSurfaces == 0 { isFeedVisible = false }
    }
    /// Host rotation adapters call this only for valid portrait / landscape device orientations.
    func deviceRotated(isLandscape: Bool) {
        guard configuration.followsDeviceRotation else { return }
        if isLandscape, (snapshot.aspectRatio ?? currentItem?.aspectRatio ?? 0) > 1 { enterFullscreen() }
        else if !isLandscape { exitFullscreen() }
    }
    /// Visible video area in the host page's coordinate system.
    public func videoFrame(for item: HMMediaItem, in bounds: CGRect) -> CGRect {
        (item.presentation ?? configuration.presentation).videoFrame(aspectRatio: snapshot(for: item).aspectRatio,
            in: bounds, tolerance: configuration.aspectRatioTolerance)
    }
    /// Current playback state, observed by SwiftUI through the underlying snapshot.
    ///
    /// Access on the main actor.
    public var snapshot: HMPlaybackSnapshot { currentItem.map { snapshot(for: $0) } ?? pendingSnapshot }
    /// True while requesting a page from the optional playlist source.
    ///
    /// Access on the main actor.
    public private(set) var isLoadingPage = false
    /// Whether the source has another page. False without a source.
    ///
    /// Access on the main actor.
    public private(set) var hasMoreContent = false
    /// Latest recoverable error description; a successful operation clears it.
    ///
    /// Access on the main actor.
    public private(set) var loadError: String?
    /// Most recent event, also available to Observation clients.
    ///
    /// Access on the main actor.
    public private(set) var lastEvent: HMPlayerEvent?
    /// Increments after each effective playlist edit. Appends preserve in-flight swipes.
    ///
    /// Access on the main actor.
    public private(set) var playlistRevision = 0
    /// Last effective edit, including metadata-only edits. Nil before the first edit.
    /// No-ops and rejected edits preserve this value. Access on the main actor.
    public private(set) var lastPlaylistChange: HMPlaylistChange?
    /// Optional paging adapter. Assigning a source (including the same instance) resets its cursor and cancels its pending page; loaded entries remain. Call loadNextPage for an immediate fetch.
    ///
    /// Access on the main actor.
    public var playlistSource: HMPlaylistSource? {
        didSet { pageGeneration += 1; loadTask?.cancel(); loadTask = nil; pageTaskID = UUID(); isLoadingPage = false; resetPagingCursor(); scheduleFailedItemAdvance() }
    }
    /// Playback and prefetch settings. Updating these may resize the engine pool.
    ///
    /// Access on the main actor.
    public var configuration: HMPlayerConfiguration { didSet { diagnosticsRecorder?.configure(configuration); applyConfiguration() } }
    /// Replaceable measured-performance policy. Fixed mode bypasses custom providers.
    ///
    /// Access on the main actor.
    @ObservationIgnored public var prefetchPolicy: any HMPrefetchPolicyProviding = HMAdaptivePrefetchPolicy() {
        didSet { prefetchIdentity = ""; updatePrefetch(force: true) }
    }
    /// Last applied, app-clamped decision, including its reason.
    ///
    /// Access on the main actor.
    public private(set) var prefetchPlan: HMPrefetchPlan?
    /// Mutes every current and prepared player synchronously.
    ///
    /// Access on the main actor.
    public var isMuted: Bool { didSet { for node in pool.nodes { node.setMuted(isMuted) }; adNode?.setMuted(isMuted) } }
    /// Pause when hidden or backgrounded. Resume is synchronous for a resolved, prepared current item.
    ///
    /// Access on the main actor.
    public var isFeedVisible = true {
        didSet {
            guard isFeedVisible != oldValue else { return }
            if isFeedVisible && !appBackgrounded { diagnosticsRecorder?.resume() }
            else { diagnosticsRecorder?.suspend() }
            updateHostPlaybackPermission()
            if isFeedVisible { Task { [weak self] in await self?.prepareTransport() }; activateAudioIfManaged(); refreshWindow() }
            else { pauseAll() }
        }
    }
    /// Analytics fan-out, independent of the player event stream.
    ///
    /// Access on the main actor.
    @ObservationIgnored public let analytics: HMAnalyticsHub
    /// Independent ordered subscription, buffered up to 256 events. Cancel the consuming task when finished.
    ///
    /// Access on the main actor.
    public var events: AsyncStream<HMPlayerEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.subscribers[id] = nil } }
        }
    }
    /// Number of engine slots holding media; intended for diagnostics, without exposing native players.
    @_spi(Benchmark) public var preparedItemCount: Int { pool.busyCount }

    /// Native assignment generations for local Sample diagnostics; display-only edits preserve them.
    @_spi(Benchmark) public var preparedItemIdentities: [String: String] {
        Dictionary(uniqueKeysWithValues: pool.nodes.compactMap { node in
            node.item.map { ($0.id, node.id + ":" + String(node.assignmentGeneration)) }
        })
    }

    /// Read-only interaction state: feed touches/page motion or a bounded partner interaction.
    ///
    /// Access on the main actor.
    public var isInteracting: Bool { pageIsMoving || feedIsTouching || partnerIsInteracting }
    private var feedIsTouching = false
    private var partnerIsInteracting = false
    private var pageIsMoving = false { didSet { if pageIsMoving { diagnosticsRecorder?.cancelDelivery() } } }
    @ObservationIgnored private var interactionTimeoutTask: Task<Void, Never>?
    /// Defers automatic failure skips for a custom control. Repeated calls renew the 30-second timeout.
    ///
    /// Access on the main actor.
    public func beginInteraction() { beginInteraction(timeout: .seconds(30)) }
    func beginInteraction(timeout: Duration) {
        guard !ended else { return }
        partnerIsInteracting = true
        diagnosticsRecorder?.cancelDelivery()
        interactionTimeoutTask?.cancel()
        interactionTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.endInteraction()
        }
    }
    /// Ends a custom control interaction early; otherwise it expires automatically after 30 seconds.
    ///
    /// Access on the main actor.
    public func endInteraction() {
        partnerIsInteracting = false
        interactionTimeoutTask?.cancel(); interactionTimeoutTask = nil
        scheduleFailedItemAdvance()
    }
    func setFeedTouching(_ touching: Bool) {
        feedIsTouching = touching
        if touching { diagnosticsRecorder?.cancelDelivery() }
        if !touching { scheduleFailedItemAdvance() }
    }
    private var failureIdle = false
    @ObservationIgnored private var terminalFailures: Set<HMMediaItem.MediaIdentity> = []
    @ObservationIgnored private var failureAdvanceTask: Task<Void, Never>?
    @ObservationIgnored private var feedSurfaces = 0
    @ObservationIgnored private var failurePageID: String?
    @ObservationIgnored private var deferredFailureCommit: (id: String, time: TimeInterval)?
    @ObservationIgnored private var networkFailures: [HMMediaItem.MediaIdentity: HMNetworkRetry] = [:]
    @ObservationIgnored private var networkRetryTask: Task<Void, Never>?
    @ObservationIgnored private var connectivityMonitor: HMConnectivityMonitor?
    @ObservationIgnored private var lastPathSatisfied: Bool?

    var requestedPageID: String?
    var requestedPageIndex: Int? {
        if failurePageID == requestedPageID, feedIsTouching || partnerIsInteracting { return nil }
        return requestedPageID.flatMap { id in items.firstIndex { $0.id == id } }
    }
    var pageRequestID = UUID()
    @ObservationIgnored let pool: HMPlayerPool
    @ObservationIgnored private let resolver: HMItemResolver?
    @ObservationIgnored private let interactions: HMInteractionSource
    @ObservationIgnored private let resolutions = HMResolutionStore()
    @ObservationIgnored private var resolutionTasks: [HMMediaItem.MediaIdentity: Task<Void, Never>] = [:]
    @ObservationIgnored private var resolutionTaskTokens: [HMMediaItem.MediaIdentity: UUID] = [:]
    @ObservationIgnored private var resolutionSigningParameters: [String] = []
    @ObservationIgnored private var resolutionFailures: [HMMediaItem.MediaIdentity: HMResolutionRetry] = [:]
    @ObservationIgnored private var resolutionRetryTask: Task<Void, Never>?
    @ObservationIgnored private var interactionCurrent: HMMediaItem?
    @ObservationIgnored private var interactionNext: HMMediaItem?
    @ObservationIgnored private var timelines: [HMMediaItem: HMStreamTimeline] = [:]
    @ObservationIgnored private var engagements: [HMMediaItem: HMEngagement] = [:]
    @ObservationIgnored private var moderationByItemID: [String: HMModerationState] = [:]
    /// Inert stand-ins for items outside the playlist (a cell animating out), reused across body passes.
    @ObservationIgnored private var detachedEngagements: [String: HMEngagement] = [:]
    /// Playlist position by ID, rebuilt lazily after an edit; overlay bodies look items up on every tick.
    @ObservationIgnored private var idIndex: [String: Int] = [:]
    @ObservationIgnored private var itemsVersion = 0
    @ObservationIgnored private var idIndexVersion = -1
    @ObservationIgnored private var subscribers: [UUID: AsyncStream<HMPlayerEvent>.Continuation] = [:]
    @ObservationIgnored private var proxy: HMCacheProxy?
    @ObservationIgnored private var transportTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var pageGeneration = 0
    @ObservationIgnored private var cursorGeneration = 0
    @ObservationIgnored private var pagingRetry = HMPagingRetry()
    @ObservationIgnored private var pagingRetryTask: Task<Void, Never>?
    @ObservationIgnored private var pageTaskID = UUID()
    @ObservationIgnored private var prefetchIdentity = ""
    @ObservationIgnored private var measurements = HMPrefetchMeasurements()
    @ObservationIgnored private var activatedAt: TimeInterval?
    @ObservationIgnored private var arrivalDwell: TimeInterval?
    @ObservationIgnored private var lastDecisionAt = -Double.infinity
    @ObservationIgnored private var nextCursor: String?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var ended = false
    private(set) var wantsPlayback = true
    @ObservationIgnored private var prefetchSafe = false
    @ObservationIgnored private var requestTime = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private var requestReason = "initial"
    @ObservationIgnored private var requestCommit: HMPageCommit?
    @ObservationIgnored private var playedActivationID = ""
    @ObservationIgnored private var startCapLowered = false
    @ObservationIgnored private var headPair = ""
    @ObservationIgnored private var resumePositions: [HMMediaItem.MediaIdentity: TimeInterval] = [:]
    /// One rebuilt activation, independent of the ordinary back-swipe resume policy.
    @ObservationIgnored private var mediaResetPosition: (item: HMMediaItem.MediaIdentity, seconds: TimeInterval)?
    @ObservationIgnored private var nearingEndKey = ""
    private var pendingSnapshot = HMPlaybackSnapshot()

    /// Creates an empty player. Supply only the adapters your app needs; no Core dependency is required.
    ///
    /// Access on the main actor.
    public init(configuration: HMPlayerConfiguration = .default, resolver: HMItemResolver? = nil,
                interactions: HMInteractionSource? = nil, analytics: HMAnalyticsHub? = nil) {
        self.configuration = configuration; self.resolver = resolver
        // Without a source there is no engagement: an empty, read-only timeline. Demo content is opt-in.
        self.interactions = interactions ?? HMEmptyInteractionSource()
        self.analytics = analytics ?? HMAnalyticsHub(); isMuted = configuration.startsMuted
        pool = HMPlayerPool(configuration: configuration)
        resolutionSigningParameters = configuration.volatileSigningQueryParameters
        resolutions.configure(signingParameters: configuration.volatileSigningQueryParameters)
        pool.onEvent = { [weak self] event, item in self?.handle(event, item: item) }
        pool.willRecycle = { [weak self] node, item in self?.analytics.videoChange(playerKey: node.id, item: item) }
        pool.didCreate = { [weak self] node in self?.wire(node) }
        for node in pool.nodes { wire(node) }
        captionObserver = HMCaptionSettingsObserver { [weak self] in
            guard let self else { return }
            self.systemCaptionsEnabled = MACaptionAppearanceGetDisplayType(.user) == .alwaysOn
            self.captionStyleRevision += 1
            self.updateCaptions()
        }
        #if os(iOS)
        audioObserver = HMAudioObserver { [weak self] in self?.handleAudioNotification($0) }
        #endif
        connectivityMonitor = HMConnectivityMonitor { [weak self] satisfied in
            Task { @MainActor [weak self] in self?.connectivityChanged(satisfied: satisfied) }
        }
    }

    /// Creates a player with an explicit optional diagnostics policy. Default construction stays off.
    /// Access on the main actor. The original four-argument initializer remains unchanged.
    public convenience init(configuration: HMPlayerConfiguration = .default, resolver: HMItemResolver? = nil,
                            interactions: HMInteractionSource? = nil, analytics: HMAnalyticsHub? = nil,
                            diagnostics: HMPlayerDiagnosticsConfiguration?) {
        self.init(configuration: configuration, resolver: resolver, interactions: interactions, analytics: analytics)
        setDiagnostics(diagnostics)
    }

    @ObservationIgnored private(set) var diagnosticsRecorder: HMDiagnosticsRecorder?
    @ObservationIgnored private var diagnosticsDraw: Double?
    @ObservationIgnored private var diagnosticsCadence: HMDiagnosticsCadence?

    /// Enables optional sampled aggregate diagnostics, or immediately cancels/discards with nil.
    /// Does not change playback configuration or rebuild preparation. Access on the main actor.
    public func setDiagnostics(_ options: HMPlayerDiagnosticsConfiguration?) {
        diagnosticsRecorder?.suspend()
        diagnosticsRecorder = nil
        guard !ended, let options, options.endpoint != nil else { return }
        if diagnosticsDraw == nil { diagnosticsDraw = Double.random(in: 0..<1) }
        guard diagnosticsDraw! < options.samplingPercent / 100 else { return }
        if diagnosticsCadence == nil { diagnosticsCadence = HMDiagnosticsCadence() }
        diagnosticsRecorder = HMDiagnosticsRecorder(options: options, configuration: configuration,
            lastAttempt: -.infinity, suspended: !isFeedVisible || appBackgrounded, cadence: diagnosticsCadence) { [weak self] in self?.diagnosticsEligible == true }
    }

    private var diagnosticsEligible: Bool {
        guard !ended, isFeedVisible, !appBackgrounded, !audioBlocked, !adState.isActive,
              !isInteracting, let node = currentNode, node.hasStartedMoving,
              node.snapshot.state == .playing, node.snapshot.bufferedAhead >= 3,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { return false }
        return ProcessInfo.processInfo.thermalState == .nominal || ProcessInfo.processInfo.thermalState == .fair
    }

    private func wire(_ node: HMPlayerNode) {
        node.onBufferChanged = { [weak self] in self?.updatePrefetch() }
        node.onExternalPlaybackChanged = { [weak self] in self?.syncExternalPlayback() }
        node.captions.configure(enabled: captionsEnabled, language: selectedCaptionLanguage)
        node.captions.onLanguagesChanged = { [weak self, weak node] in
            guard let self, let node, node.item?.id == self.currentItem?.id else { return }
            self.emit(.captionsChanged(enabled: self.captionsEnabled, language: self.selectedCaptionLanguage))
        }
    }

    /// Selects `items[startAt]`; effective edits reset the source cursor and its retry budget.
    /// The same selected ID and canonical source preserve playback without a current-item event.
    /// An identical list/index is a no-op, preserving failures, cursor, resume positions and loadError.
    /// A pending page finishes but is ignored. Empty with startAt zero becomes idle; invalid edits return false and emit an error.
    ///
    /// Access on the main actor.
    @discardableResult public func replaceAll(_ items: [HMMediaItem], startAt: Int = 0) -> Bool {
        mutate(replacingCurrent: true) { try $0.replaceAll(items, startAt: startAt) }
    }
    /// Reconciles a complete ranked feed around current's ID, preserving played history.
    /// Uses the replaceUpcoming path for entries after current; incoming current metadata is refreshed.
    /// Duplicate/empty IDs anywhere in the incoming list reject the entire edit. History IDs appearing
    /// after current are ignored rather than replayed. If current is absent, keeps history and uses all
    /// incoming nonhistory entries as upcoming, applying removedCurrentPolicy without replaying history.
    /// Empty lists are no-ops; history-only responses go idle immediately or after current finishes.
    /// Empty players load nonempty lists. Configured volatile signing queries do not change media identity.
    /// Access on the main actor.
    @discardableResult public func reconcile(_ list: [HMMediaItem]) -> Bool {
        mutate { try $0.reconcile(list, policy: effectiveRemovedCurrentPolicy) }
    }
    /// Replaces every entry after current, preserving the current player's clock, buffer and layer.
    ///
    /// Access on the main actor.
    @discardableResult public func replaceUpcoming(_ items: [HMMediaItem]) -> Bool { mutate { try $0.replaceUpcoming(items) } }
    /// Inserts entries immediately after current; on an empty list creates the playlist.
    ///
    /// Access on the main actor.
    @discardableResult public func insertNext(_ items: [HMMediaItem]) -> Bool { mutate { try $0.insertNext(items) } }
    /// Adds entries at the end without interrupting current playback.
    ///
    /// Access on the main actor.
    @discardableResult public func append(_ items: [HMMediaItem]) -> Bool { appendItems(items, fromSource: false) }
    private func appendItems(_ items: [HMMediaItem], fromSource: Bool) -> Bool { mutate { try $0.append(items) } }
    /// Removes IDs using removedCurrentPolicy. Deferred current stays in items until end or a swipe away.
    ///
    /// Access on the main actor.
    @discardableResult public func remove(ids: Set<String>) -> Bool { mutate { $0.remove(ids: ids, policy: effectiveRemovedCurrentPolicy) } }

    private func identity(_ item: HMMediaItem) -> HMMediaItem.MediaIdentity {
        item.mediaIdentity(ignoring: configuration.volatileSigningQueryParameters)
    }
    private var effectiveRemovedCurrentPolicy: HMRemovedCurrentPolicy {
        guard !adState.isActive, configuration.removedCurrentPolicy == .finishThenAdvance,
              !failureIdle, let item = playlist.current,
              !terminalFailures.contains(identity(item)), networkFailures[identity(item)] == nil,
              resolutionFailures[identity(item)] == nil,
              snapshot.state != .failed, currentNode?.hasReachedEnd != true else { return .advanceNow }
        let state = snapshot
        if state.duration > 0, state.currentTime >= state.duration { return .advanceNow }
        return .finishThenAdvance
    }

    private func mutate(replacingCurrent: Bool = false, request: (reason: String, time: TimeInterval)? = nil, _ edit: (inout HMPlaylistState) throws -> Void) -> Bool {
        guard !ended else { return false }
        var result = playlist
        do { try edit(&result) } catch { report(error as? HMPlayerError ?? .playlistSource(error.localizedDescription)); return false }
        guard result != playlist else { return true }
        let old = currentItem
        let oldItems = items
        let assignments = oldItems.compactMap { item in pool.nodes.first(where: { $0.item?.id == item.id }).map { ($0, item.id, $0.assignmentGeneration) } }
        let preservesMove = HMPagePosition.survives(old: items.map(\.id), new: result.items.map(\.id),
            current: old?.id, destination: requestedPageID)
        let changesSelection = playlist.current?.mediaIdentity(ignoring: configuration.volatileSigningQueryParameters) != result.current?.mediaIdentity(ignoring: configuration.volatileSigningQueryParameters)
        let nextCurrent = failureIdle && !changesSelection ? nil : result.current
        let changesCurrent = old?.mediaIdentity(ignoring: configuration.volatileSigningQueryParameters) != nextCurrent?.mediaIdentity(ignoring: configuration.volatileSigningQueryParameters)
        if changesCurrent { saveAndDeactivate() }
        // A playlist edit invalidates the automatic-failure request's provenance.
        if failurePageID != nil { requestedPageID = nil; pageRequestID = UUID() }
        failurePageID = nil; deferredFailureCommit = nil
        playlist = result; itemsVersion += 1
        let media = Set(items.map(identity))
        networkFailures = networkFailures.filter { media.contains($0.key) }
        terminalFailures.formIntersection(media)
        resolutionFailures = resolutionFailures.filter { media.contains($0.key) }
        resumePositions = resumePositions.filter { media.contains($0.key) }
        if changesSelection { failureIdle = false }
        loadError = nil; playlistRevision += 1
        if !preservesMove { requestedPageID = nil; pageRequestID = UUID() }
        // Edits do not supersede a source request: its page is merged against the
        // latest playlist on arrival. replaceAll resets the cursor and ignores an old
        // response without cancelling its fetch. Source assignment or teardown cancels it.
        if replacingCurrent { resetPagingCursor() }
        if changesCurrent {
            prefetchSafe = false; prefetchIdentity = ""; resetPagingRetry()
            requestTime = request?.time ?? ProcessInfo.processInfo.systemUptime; requestReason = request?.reason ?? "play"
            if request == nil { requestCommit = HMPageCommit(source: .api, time: requestTime) }
            pendingSnapshot = HMPlaybackSnapshot(); pendingSnapshot.state = currentItem == nil ? .idle : .loading
            emit(.currentItemChanged(currentItem))
        }
        refreshWindow()
        lastPlaylistChange = HMPlaylistChange(old: oldItems, new: items, currentChanged: changesCurrent,
            releasedItemIDs: assignments.compactMap { node, id, revision in
                node.item?.id != id || node.assignmentGeneration != revision ? id : nil
            })
        emit(.playlistChanged(items))
        checkEnd(); scheduleFailedItemAdvance()
        return true
    }

    /// Begins playback, or resumes the current item without resetting its position.
    ///
    /// Access on the main actor.
    public func play() {
        #if os(iOS)
        audioInterrupted = false; resumeAfterInterruption = false
        #endif
        wantsPlayback = true; activateAudioIfManaged(); updateHostPlaybackPermission(); resumeActive(); refreshWindow()
    }
    /// Pauses playback without changing the playlist or current position.
    ///
    /// Access on the main actor.
    public func pause() {
        wantsPlayback = false
        #if os(iOS)
        resumeAfterInterruption = false
        #endif
        updateHostPlaybackPermission()
        if currentNode?.isActive == true { currentNode?.pause() }
        adNode?.pause()
    }
    /// Seeks to a VOD time in seconds, clamped to the known duration.
    ///
    /// Access on the main actor.
    public func seek(to seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0 else { report(.invalidSeek, item: currentItem); return }
        guard !adState.isActive else { return }
        currentNode?.seek(to: seconds)
    }
    /// Moves to the next entry, if any.
    ///
    /// Access on the main actor.
    public func next() { navigate(to: playlist.current == nil ? playlist.index : activeIndex + 1) }
    /// Moves to the previous entry, if any.
    ///
    /// Access on the main actor.
    public func previous() { navigate(to: activeIndex - 1) }
    /// Moves to a playlist ID and explicitly retries its remembered media/resolution failures,
    /// including when that ID is already selected. An unknown ID emits an invalid-index error.
    ///
    /// Access on the main actor.
    public func jump(toID id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { report(.invalidIndex(-1)); return }
        navigate(to: index)
    }
    private func navigate(to index: Int, reason: String = "play", requestedAt: TimeInterval = ProcessInfo.processInfo.systemUptime, commit: HMPageCommit? = nil, retryFailed: Bool = true) {
        guard items.indices.contains(index), !ended else { return }
        requestCommit = commit ?? HMPageCommit(source: .api, time: requestedAt)
        if let finishingID = playlist.finishingID, items[index].id != currentItem?.id {
            let destination = items[index].id
            arrivalDwell = index == activeIndex + 1 ? activatedAt.map { max(0, requestedAt - $0) } : nil
            mutate(request: (reason, requestedAt)) {
                $0.remove(ids: [finishingID])
                $0.index = $0.items.firstIndex { $0.id == destination } ?? $0.index
            }
            requestedPageID = nil; failurePageID = nil; deferredFailureCommit = nil
            return
        }
        let changesCurrent = failureIdle || playlist.current == nil || index != playlist.index
        if changesCurrent {
            arrivalDwell = index == activeIndex + 1 ? activatedAt.map { max(0, requestedAt - $0) } : nil
            resetPagingRetry(); saveAndDeactivate(); failureIdle = false; playlist.index = index; pendingSnapshot = HMPlaybackSnapshot(); pendingSnapshot.state = .loading; emit(.currentItemChanged(currentItem)) }
        if retryFailed, let currentItem {
            let hadNetworkFailure = networkFailures.removeValue(forKey: identity(currentItem)) != nil
            let hadResolutionFailure = resolutionFailures.removeValue(forKey: identity(currentItem)) != nil
            let wasTerminal = terminalFailures.remove(identity(currentItem)) != nil
            if wasTerminal || currentNode?.snapshot.state == .failed { currentNode?.release() }
            if hadResolutionFailure || hadNetworkFailure || wasTerminal { pendingSnapshot = HMPlaybackSnapshot(); pendingSnapshot.state = .loading }
        }
        requestedPageID = nil; failurePageID = nil; deferredFailureCommit = nil; requestTime = requestedAt; requestReason = reason
        prefetchSafe = false; prefetchIdentity = ""; refreshWindow(); checkEnd(); scheduleFailedItemAdvance()
    }
    /// Requests a view-driven animated page move; activation waits until scrolling settles.
    @_spi(Benchmark) public func requestPage(at index: Int) {
        guard !isFullscreen, !isAdSwipeBlocked, items.indices.contains(index), index != currentIndex else { return }
        requestedPageID = items[index].id; pageRequestID = UUID()
    }
    /// Commits a page without a gesture or scroll callback (failure skips, feed detach).
    func commitPage(toID id: String, requestedAt: TimeInterval) {
        commitPage(toID: id, commit: HMPageCommit(source: .api, time: requestedAt))
    }
    func commitPage(toID id: String, commit: HMPageCommit) {
        guard !isFullscreen, !isAdSwipeBlocked else { return }
        // Removing the last upcoming entry may leave history visible in the scroll view.
        // Layout settling must not turn that retained history into a new playback visit.
        guard currentItem != nil || requestedPageID == id || failurePageID == id else { return }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        // Native settle and SwiftUI's quiet fallback may both report this page, and a
        // lift activation's own settle follows it. A duplicate must not replace the
        // original action clock during resolution; it only records the settle.
        guard id != currentItem?.id else {
            let confirmsLift = requestCommit?.source == .lift && requestCommit?.settle == nil && commit.lift != nil && requestCommit?.lift == commit.lift
            recordSettle(of: commit)
            recordGesture(commit, landedOn: id, outcome: confirmsLift ? "lift-confirmed" : "cancelled")
            // Only a finger cancels an animated request to another page. A stray
            // report of the current page used to drop the request for good.
            if commit.isGesture || requestedPageID == nil || requestedPageID == id {
                requestedPageID = nil; failurePageID = nil; deferredFailureCommit = nil
            }
            return
        }
        let failedMove = failurePageID == id
        if failedMove, feedIsTouching || partnerIsInteracting {
            deferredFailureCommit = (id, commit.time)
            return
        }
        recordGesture(commit, landedOn: id, outcome: commit.source == .lift ? "lift-activated" : commit.correction == nil ? "settle-activated" : "corrected")
        navigate(to: index, reason: failedMove ? "failed-item" : "swipe",
                 requestedAt: commit.time, commit: commit, retryFailed: false)
    }
    /// A lift activation learns its settle clock when the page comes to rest.
    private func recordSettle(of commit: HMPageCommit) {
        guard let settle = commit.settle, var current = requestCommit, current.source == .lift, current.settle == nil else { return }
        current.settle = settle; requestCommit = current
        currentNode?.recordSettle(settle)
    }
    /// Benchmark-only record of each finger gesture: its clocks and what it did.
    private func recordGesture(_ commit: HMPageCommit, landedOn id: String, outcome: String) {
        guard commit.isGesture, let item = items.first(where: { $0.id == id }) else { return }
        var properties = commit.properties; properties["outcome"] = outcome
        analytics.recordBenchmark(HMPlaybackEvent(kind: .pageGesture, itemID: id, metrics: commit.clockMetrics, properties: properties), item: item)
    }
    func attachFeed() { feedSurfaces += 1; isFeedVisible = true }
    func detachFeed() {
        feedSurfaces = max(0, feedSurfaces - 1)
        pageIsMoving = false; feedIsTouching = false
        if feedSurfaces == 0, let id = requestedPageID, failurePageID == id {
            commitPage(toID: id, requestedAt: ProcessInfo.processInfo.systemUptime)
        }
        scheduleFailedItemAdvance()
    }
    func setPageMoving(_ moving: Bool) {
        pageIsMoving = moving
        if !moving { scheduleFailedItemAdvance() }
    }
    /// Prepares transport before presenting a selected playlist index, preserving the request clock for analytics.
    @_spi(Benchmark) public func requestPlay(at index: Int, requestedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) async {
        guard items.indices.contains(index) else { return }
        let selected = items[index]
        #if os(iOS)
        audioInterrupted = false; resumeAfterInterruption = false
        #endif
        activateAudioIfManaged()
        await prepareTransport()
        guard let index = items.firstIndex(of: selected), !ended else { return }
        wantsPlayback = true; navigate(to: index, requestedAt: requestedAt); isFeedVisible = true
    }
    private func saveAndDeactivate() {
        mediaResetPosition = nil
        if adState.isActive { endAd(.cancelled, resume: false) }
        adVisit = nil; adState = .none; adProgress = HMAdProgress(); adContentOutcome = nil
        guard let node = currentNode, let item = currentItem else { return }
        resumePositions[identity(item)] = node.snapshot.currentTime
        node.deactivate(retainingPosition: configuration.restoresPlaybackPosition)
    }

    /// Loads the first page once, if a playlist source is assigned. Feed views call this automatically.
    ///
    /// Access on the main actor.
    public func start() async {
        if isFeedVisible { activateAudioIfManaged() }
        guard !ended else { return }
        let firstStart = !hasStarted; hasStarted = true
        if playlistSource != nil, firstStart || items.isEmpty { await fetchNextPage() }
        refreshWindow()
    }
    /// Requests one page, resetting the automatic retry budget. Concurrent calls while loading do nothing.
    /// Failed pages retry automatically after 1, 2 and 4 seconds near the end, then stop until navigation or another explicit call.
    ///
    /// Access on the main actor.
    public func loadNextPage() async {
        guard !isLoadingPage, hasMoreContent, playlistSource != nil, !ended else { return }
        resetPagingRetry()
        await fetchNextPage()
    }
    private func resetPagingRetry() {
        pagingRetryTask?.cancel(); pagingRetryTask = nil
        pagingRetry = HMPagingRetry(); loadError = nil
    }
    private func resetPagingCursor() {
        cursorGeneration += 1; nextCursor = nil
        hasMoreContent = playlistSource != nil
        resetPagingRetry()
    }
    private func fetchNextPage() async {
        guard !isLoadingPage, hasMoreContent, let source = playlistSource, !ended,
              pagingRetry.canRetry(at: ProcessInfo.processInfo.systemUptime) else { return }
        let generation = pageGeneration, cursorVersion = cursorGeneration
        isLoadingPage = true
        defer {
            if generation == pageGeneration {
                isLoadingPage = false
                if loadTask == nil { checkEnd() }
                scheduleFailedItemAdvance()
            }
        }
        do {
            let page = try await source.loadPage(cursor: nextCursor)
            try Task.checkCancellation()
            guard generation == pageGeneration, cursorVersion == cursorGeneration, !ended else { return }
            let filtered = playlist.filterSourcePage(page.items)
            // Validate before the mutation path so a rejected page records one failure
            // and one error, just like a thrown source error.
            var validated = playlist
            try validated.append(filtered.items)
            guard appendItems(filtered.items, fromSource: true) else { return }
            let previousCursor = nextCursor
            nextCursor = page.nextCursor; hasMoreContent = page.nextCursor != nil && page.nextCursor != previousCursor
            resetPagingRetry()
            if !filtered.duplicates.isEmpty { emit(.sourcePageDuplicates(ids: filtered.duplicates)) }
        } catch is CancellationError { }
        catch {
            if generation == pageGeneration, cursorVersion == cursorGeneration, !ended {
                pagingRetry.failed(at: ProcessInfo.processInfo.systemUptime)
                report(.playlistSource(error.localizedDescription))
            }
        }
    }
    private func checkEnd() {
        guard !ended else { return }
        let remaining = max(0, items.count - playlist.index - 1)
        guard remaining <= max(0, configuration.lowWaterMark) else { nearingEndKey = ""; return }
        let key = "\(playlistRevision):\(activeIndex)"
        if currentItem != nil, key != nearingEndKey { nearingEndKey = key; emit(.nearingEnd(remaining: remaining)) }
        guard hasMoreContent, !isLoadingPage, loadTask == nil, !pagingRetry.exhausted else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard pagingRetry.canRetry(at: now) else {
            guard pagingRetryTask == nil else { return }
            let delay = pagingRetry.nextAttempt - now
            pagingRetryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self else { return }
                pagingRetryTask = nil; checkEnd()
            }
            return
        }
        let token = UUID(); pageTaskID = token
        loadTask = Task { [weak self] in
            guard let self else { return }
            await fetchNextPage()
            if pageTaskID == token { loadTask = nil; checkEnd() }
        }
    }

    private func prepareTransport() async {
        guard !ended else { return }
        if let transportTask { await transportTask.value; return }
        transportTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let proxy { try await proxy.start(); return }
                let created = try HMCacheProxy(configuration: configuration)
                created.onEvent = { [weak self] event, item in self?.handle(event, item: item) }
                try await created.start()
                guard !ended else { _ = await created.finish(); return }
                proxy = created
            } catch { report(.playback("Cache transport: \(error.localizedDescription)")) }
        }
        await transportTask?.value
        transportTask = nil
    }
    private var windowItems: [HMMediaItem] {
        guard !failureIdle else { return [] }
        let resolved = max(0, min(32, configuration.resolveAhead))
        let warm = configuration.strategy == .S2 || configuration.prefetch.ahead > 0 ? configuration.warmOffsets : []
        return playlist.window(offsets: [0] + configuration.prefetch.windowOffsets + warm +
            (resolved > 0 ? Array(1...resolved) : []))
    }

    /// Media retention excludes the metadata-only resolution horizon.
    private var mediaWindowItems: [HMMediaItem] {
        guard !failureIdle else { return [] }
        return playlist.window(offsets: [0] + configuration.prefetch.windowOffsets + configuration.warmOffsets)
    }
    private func refreshWindow() {
        guard !ended else { return }
        if mediaResetPosition?.item != currentItem.map(identity) { mediaResetPosition = nil }
        // Fetch the next sidecar alongside the protected media head, including one-player configurations.
        prefetchCaptions()
        consultAdIfNeeded()
        if let currentItem, resolutions.cached(currentItem) == nil {
            pendingSnapshot.readinessTier = .resolving
            if terminalFailures.contains(identity(currentItem)) { pendingSnapshot.state = .failed }
        }
        updateInteractions()
        for node in pool.nodes { node.finishesThenLeaves = node.item?.id == playlist.finishingID && playlist.finishingID != nil }
        let window = windowItems
        resolutions.retain(Set(window))
        let windowMedia = Set(window.map(identity))
        for (key, task) in resolutionTasks where !windowMedia.contains(key) { task.cancel(); resolutionTasks[key] = nil; resolutionTaskTokens[key] = nil }
        let currentIDs = Set(items.map(\.id)), media = Set(items.map(identity))
        resumePositions = resumePositions.filter { media.contains($0.key) }
        moderationByItemID = moderationByItemID.filter { currentIDs.contains($0.key) }
        // Engagement follows the window (plus the entry just behind current, for a swipe back). One
        // the viewer has sent, reacted or voted in survives anywhere in the playlist so that isn't lost.
        let keep = Set(window + [currentItem].compactMap { $0 } + (items.indices.contains(activeIndex - 1) ? [items[activeIndex - 1]] : []))
        for entry in Array(engagements.keys) {
            if let updated = items.first(where: { $0.hasSameMedia(as: entry, ignoring: configuration.volatileSigningQueryParameters) }), updated != entry {
                let engagement = engagements.removeValue(forKey: entry)
                engagement?.updateItem(resolutions.cached(updated) ?? updated)
                engagements[updated] = engagement
                if let timeline = timelines.removeValue(forKey: entry) { timelines[updated] = timeline }
            }
        }
        engagements = engagements.filter { items.contains($0.key) && (keep.contains($0.key) || $0.value.holdsViewerState) }
        // Same rule for timelines; a kept engagement keeps its timeline so both stay one instance.
        timelines = timelines.filter { items.contains($0.key) && (keep.contains($0.key) || engagements[$0.key] != nil) }
        for (entry, engagement) in engagements {
            if let resolved = resolutions.cached(entry) ?? resolutions.cached(entry, requireFormat: false) { engagement.updateItem(resolved) }
        }
        resolutionFailures = resolutionFailures.filter { media.contains($0.key) }
        let warm: [HMMediaItem] = currentItem == nil ? [] : configuration.warmOffsets.compactMap { offset in
            let i = playlist.index + offset; return items.indices.contains(i) ? items[i] : nil
        }
        // A decision (including no fill) must not evict a warm back-swipe assignment.
        // Accepted breaks retain existing neighbours too; only new bulk preparation is gated.
        if !adState.isActive || (configuration.prefetch.ahead == 0 && configuration.prefetch.behind == 0) {
            pool.trim(keeping: Set(([currentItem].compactMap { $0 } + warm).compactMap { resolutions.cached($0) }))
        }
        let playable = mediaWindowItems.compactMap { resolutions.cached($0) }
        proxy?.retainWindow(playable)
        proxy?.retainPlaylist(items.compactMap { resolutions.cached($0) })
        guard isFeedVisible, currentItem != nil else { return }
        if proxy == nil {
            Task { [weak self] in guard let self else { return }; await prepareTransport(); guard !ended else { return }; refreshWindow() }
            return
        }
        proxy?.setProgressAllowed(mediaProgressAllowed)
        refreshWindowAfterTransport()
        scheduleNetworkRetry()
    }
    private func refreshWindowAfterTransport() {
        guard !ended, isFeedVisible else { return }
        resolutionRetryTask?.cancel(); resolutionRetryTask = nil
        let mediaIDs = Set(playlist.window(offsets: [0] + (prefetchPlan?.windowOffsets ?? configuration.prefetch.windowOffsets) +
            configuration.warmOffsets).map(\.id))
        let retryTargets = networkRetryTargets
        for item in windowItems {
            let metadataOnly = item != currentItem && !(adState.isActive && item.id == items.dropFirst(activeIndex + 1).first?.id) && ((configuration.adaptive && !prefetchSafe) || !mediaIDs.contains(item.id))
            let urgent = item == currentItem || item == items.dropFirst(activeIndex + 1).first
            if urgent { resolutions.promote(item) }
            guard !terminalFailures.contains(identity(item)), resolutions.cached(item, requireFormat: !metadataOnly) == nil, resolutionTasks[identity(item)] == nil,
                  resolutionFailures[identity(item)]?.canRetry(at: ProcessInfo.processInfo.systemUptime) != false,
                  networkFailures[identity(item)].map({ retryTargets.contains(identity(item)) && (!$0.nextAttempt.isFinite || $0.nextAttempt <= ProcessInfo.processInfo.systemUptime) }) != false else { continue }
            let resolutionKey = identity(item), token = UUID()
            resolutionTaskTokens[resolutionKey] = token
            resolutionTasks[resolutionKey] = Task(priority: urgent ? .userInitiated : .utility) { [weak self] in
                guard let self else { return }
                defer {
                    if resolutionTaskTokens[resolutionKey] == token {
                        resolutionTasks[resolutionKey] = nil; resolutionTaskTokens[resolutionKey] = nil
                    }
                }
                do {
                    let result = try await resolutions.resolve(item, using: resolver, metadataOnly: metadataOnly)
                    try Task.checkCancellation()
                    guard resolutionTaskTokens[resolutionKey] == token else { return }
                    guard windowItems.contains(where: { $0.hasSameMedia(as: item, ignoring: configuration.volatileSigningQueryParameters) }), !ended else { return }
                    guard let url = result.url, ["file", "http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw HMPlayerError.unsupportedURL }
                    resolutionTasks[resolutionKey] = nil; resolutionTaskTokens[resolutionKey] = nil; resolutionFailures[identity(item)] = nil; networkFailures[identity(item)] = nil
                    refreshWindow()
                } catch is CancellationError {
                    guard !Task.isCancelled, resolutionTaskTokens[resolutionKey] == token, !ended else { return }
                    resolutionTasks[resolutionKey] = nil; resolutionTaskTokens[resolutionKey] = nil
                    var failure = resolutionFailures[resolutionKey] ?? HMResolutionRetry()
                    failure.failed(at: ProcessInfo.processInfo.systemUptime); resolutionFailures[resolutionKey] = failure
                    report(.resolution("Resolver cancelled its work"), item: item)
                    if failure.attempts >= HMResolutionRetry.maximumAttempts { markTerminalFailure(item) }
                    scheduleResolutionRetry()
                }
                catch {
                    guard !Task.isCancelled, resolutionTaskTokens[resolutionKey] == token, windowItems.contains(where: { $0.hasSameMedia(as: item, ignoring: configuration.volatileSigningQueryParameters) }), !ended else { return }
                    resolutionTasks[resolutionKey] = nil; resolutionTaskTokens[resolutionKey] = nil
                    if HMNetworkFailure.isTransient(error) {
                        if currentItem?.hasSameMedia(as: item, ignoring: configuration.volatileSigningQueryParameters) == true { pendingSnapshot.state = .loading }
                        report(error as? HMPlayerError ?? .resolution(error.localizedDescription), item: item)
                        markNetworkFailure(item)
                        return
                    }
                    networkFailures[identity(item)] = nil
                    var failure = resolutionFailures[identity(item)] ?? HMResolutionRetry()
                    failure.failed(at: ProcessInfo.processInfo.systemUptime); resolutionFailures[identity(item)] = failure
                    let kind = error as? HMPlayerError ?? .resolution(error.localizedDescription)
                    if currentItem?.hasSameMedia(as: item, ignoring: configuration.volatileSigningQueryParameters) == true {
                        pendingSnapshot.state = failure.attempts >= HMResolutionRetry.maximumAttempts ? .failed : .loading
                        pendingSnapshot.errorDescription = kind.localizedDescription
                    }
                    report(kind, item: item)
                    if failure.attempts >= HMResolutionRetry.maximumAttempts { markTerminalFailure(item) }
                    advanceRemovedFailureIfNeeded(); scheduleResolutionRetry()
                }
            }
        }
        scheduleResolutionRetry(); resumeActive()
        for node in pool.nodes { node.finishesThenLeaves = node.item?.id == playlist.finishingID && playlist.finishingID != nil }
        updatePrefetch()
    }
    private func scheduleResolutionRetry() {
        guard isFeedVisible, !ended else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let deadlines = windowItems.compactMap { item -> TimeInterval? in
            guard resolutionTasks[identity(item)] == nil, let retry = resolutionFailures[identity(item)], retry.attempts < HMResolutionRetry.maximumAttempts else { return nil }
            return retry.nextAttempt
        }
        guard let deadline = deadlines.min() else { return }
        resolutionRetryTask?.cancel()
        resolutionRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.01, deadline - now))) } catch { return }
            self?.refreshWindow()
        }
    }
    private func resumeActive() {
        guard !audioBlocked else { return }
        proxy?.setProgressAllowed(mediaProgressAllowed)
        if adNode?.isActive == true, isFeedVisible, wantsPlayback { adNode?.play() }
        guard isFeedVisible, !ended, let original = currentItem, !terminalFailures.contains(identity(original)),
              networkFailures[identity(original)].map({ $0.nextAttempt.isFinite }) != true, let item = resolutions.cached(original), let url = item.url else { return }
        guard ["file", "http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        if currentNode?.isActive != true { proxy?.prioritizePlayback(item, urgent: configuration.strategy != .S2, admitting: admittedNext()) }
        let node = pool.node(for: item, protecting: [item.id], playbackURL: proxy?.url(for: item))
        node.onBufferChanged = { [weak self] in self?.updatePrefetch() }
        node.setMuted(isMuted)
        node.captions.configure(enabled: captionsEnabled, language: selectedCaptionLanguage)
        analytics.attach(playerLayer: node.playerLayer, playerKey: node.id, item: item)
        if adState.isActive {
            if !prefetchIdentity.isEmpty { proxy?.cancelPrefetch(); prefetchIdentity = "" }
            if node.isActive { node.pause() }
            prepareAdHeads()
            return
        }
        if !node.isActive {
            proxy?.markPlayed(item)
            let resetPosition = mediaResetPosition.flatMap { $0.item == identity(original) ? $0.seconds : nil }
            mediaResetPosition = nil
            node.activate(startingAt: resetPosition ?? (configuration.restoresPlaybackPosition ? resumePositions[identity(original)] : nil),
                          requestedAt: requestTime, reason: requestReason, cachedBytes: proxy?.cachedByteCount(for: item) ?? 0, commit: requestCommit)
            if !playbackAllowed { node.pause() }
        } else if wantsPlayback && (node.snapshot.state == .paused || node.player.timeControlStatus == .paused) { node.play() }
    }
    /// Fixed mode separates request ordering from progress permission. Current reads
    /// have priority, one immediate-next prefix can progress during cold startup,
    /// and farther prefixes keep their identity while pressure temporarily holds them.
    private func updateFixedPrefetch() {
        guard isFeedVisible, !audioBlocked, !ended, let item = currentItem else { return }
        let node = currentNode
        let hasPlayed = node?.hasStartedMoving == true || (node?.snapshot.activationID == playedActivationID && !playedActivationID.isEmpty)
        let stalling = HMPlaybackPriority.isStalling(buffering: node?.snapshot.state == .buffering,
            hasPlayed: hasPlayed, bufferedAhead: node?.snapshot.bufferedAhead ?? 0)
        let urgent = configuration.strategy != .S2 && HMPlaybackPriority.isUrgent(
            displayed: node?.snapshot.timeToFirstFrame != nil, stalling: stalling)
        let next = items.indices.contains(activeIndex + 1) && !terminalFailures.contains(identity(items[activeIndex + 1])) ?
            resolutions.cached(items[activeIndex + 1]) : nil
        proxy?.prioritizePlayback(resolutions.cached(item) ?? item, urgent: urgent,
            admitting: configuration.prefetch.ahead > 0 && !(stalling && hasPlayed) ? next : nil)
        let plan = HMPrefetchPlan(itemsAhead: configuration.prefetch.ahead, itemsBehind: configuration.prefetch.behind,
            bytesPerItem: configuration.prefetch.bytesPerItem, secondsPerItem: configuration.prefetch.secondsPerItem,
            keepReadyPlayer: true, startingBitRate: configuration.startupPeakBitRate,
            concurrency: min(1, configuration.maxPrefetchConcurrency), reason: "fixed+independent-next").clamped(to: configuration)
        prefetchSafe = true
        if prefetchPlan != plan {
            prefetchPlan = plan
            analytics.recordPrefetchDecision(inputs: .init(bufferedAheadSeconds: node?.snapshot.bufferedAhead ?? 0),
                plan: plan, item: item, policy: "fixed")
            pool.configuration = configuration; pool.applyConfiguration()
        }
        let warm = plan.keepReadyPlayer ? configuration.warmOffsets.compactMap { offset -> HMMediaItem? in
            let index = activeIndex + offset
            guard items.indices.contains(index), !terminalFailures.contains(identity(items[index])) else { return nil }
            return resolutions.cached(items[index])
        } : []
        pool.trim(keeping: Set([resolutions.cached(item)].compactMap { $0 } + warm))
        let data = (1...max(1, plan.itemsAhead)).prefix(plan.itemsAhead).compactMap { offset -> HMMediaItem? in
            let index = activeIndex + offset
            guard items.indices.contains(index), !terminalFailures.contains(identity(items[index])) else { return nil }
            return resolutions.cached(items[index])
        }
        let workIdentity = plan.workIdentity + "|" + item.id + "|" + data.map {
            $0.id + ($0.url.map { HMCacheKey.canonical($0, ignoring: configuration.volatileSigningQueryParameters) } ?? "")
        }.joined(separator: "|")
        if configuration.strategy.usesDataCache, workIdentity != prefetchIdentity {
            prefetchIdentity = workIdentity
            proxy?.prefetch(data, keeping: mediaWindowItems.compactMap { resolutions.cached($0) }, plan: plan)
        }
        for entry in warm where pool.existingNode(for: entry) == nil {
            // Issued and queued prefixes cannot yet be joined. A completed head is
            // read from cache; an active head shares its transfer with native reads.
            if configuration.strategy.usesDataCache, proxy?.isPrefetching(entry) == true,
               proxy?.isPrefetchRunning(entry) != true { continue }
            let prepared = pool.node(for: entry, protecting: Set([item.id, next?.id].compactMap { $0 }), playbackURL: proxy?.url(for: entry))
            prepared.onBufferChanged = { [weak self] in self?.updatePrefetch() }; prepared.setMuted(isMuted)
        }
    }

    private func updatePrefetch(force: Bool = false) {
        if adState.isActive { prepareAdHeads(); return }
        if !configuration.adaptive { updateFixedPrefetch(); return }
        guard isFeedVisible, !audioBlocked, !ended, let node = currentNode, node.isActive, let item = currentItem else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let t = configuration.adaptiveThresholds
        let hasPlayed = node.hasStartedMoving || (!playedActivationID.isEmpty && playedActivationID == node.snapshot.activationID)
        let stalling = HMPlaybackPriority.isStalling(buffering: node.snapshot.state == .buffering, hasPlayed: hasPlayed,
                                                     bufferedAhead: node.snapshot.bufferedAhead)
        let playbackUrgent = configuration.strategy != .S2 && HMPlaybackPriority.isUrgent(displayed: node.snapshot.timeToFirstFrame != nil,
                                                        stalling: stalling)
        let admitted = admittedNext(rebuffering: stalling && hasPlayed)
        proxy?.prioritizePlayback(resolutions.cached(item) ?? item, urgent: playbackUrgent, admitting: admitted)
        let dangerous = playbackUrgent || !node.snapshot.bufferedAhead.isFinite ||
            node.snapshot.bufferedAhead < max(nonnegative(t.safetyBufferSeconds), nonnegative(configuration.prefetch.startThreshold) * 0.5)
        // Evaluate on the existing 100ms buffer ticks at most four times/sec;
        // safety transitions bypass the cadence and are applied immediately.
        guard force || now - lastDecisionAt >= 0.25 || (prefetchSafe && dangerous) else { return }
        lastDecisionAt = now
        let inputs = HMPrefetchInputs(throughputBytesPerSecond: measurements.throughput,
            latencySeconds: measurements.latency, readyHitRate: measurements.hitRate, dwellSeconds: measurements.dwell,
            bufferedAheadSeconds: node.snapshot.bufferedAhead,
            remainingSeconds: node.snapshot.duration > 0 ? max(0, node.snapshot.duration - node.snapshot.currentTime) : nil,
            isStalling: stalling, wasPaused: !prefetchSafe,
            elapsedOnItemSeconds: max(0, now - (activatedAt ?? now)), previousPlan: prefetchPlan)
        var plan = (configuration.adaptive ? prefetchPolicy.decide(inputs, configuration: configuration) :
                    HMAdaptivePrefetchPolicy().decide(inputs, configuration: configuration)).clamped(to: configuration)
        // The safety gate is enforced even for a custom provider. Fixed mode
        // preserves the existing benchmark threshold/hysteresis and S2 control.
        let safety = HMAdaptivePrefetchPolicy().decide(inputs, configuration: configuration).paused
        if configuration.adaptive { plan.paused = plan.paused || safety }
        else {
            plan.paused = configuration.strategy != .S2 && !HMBufferSafety.isSafe(ahead: inputs.bufferedAheadSeconds,
                remaining: inputs.remainingSeconds ?? 0, hasDuration: inputs.remainingSeconds != nil,
                threshold: nonnegative(configuration.prefetch.startThreshold), wasSafe: prefetchSafe)
            plan.paused = plan.paused || inputs.isStalling
        }
        if configuration.strategy == .S2 {
            plan.paused = false; plan.keepReadyPlayer = true
            plan.concurrency = configuration.maxPrefetchConcurrency; plan.startAfterSeconds = 0
        } else if playbackUrgent { plan.paused = true; plan.reason += "+active-playback" }
        // AVPlayer and HLS prefetch must start on the same rung (HMStartCap).
        if configuration.strategy.usesDataCache {
            startCapLowered = HMStartCap.isLowered(throughput: measurements.throughput, samples: measurements.throughputSamples,
                                                   wasLowered: startCapLowered, thresholds: t)
            let cap = HMStartCap.bitRate(plan.startingBitRate, lowered: startCapLowered, thresholds: t)
            if cap != plan.startingBitRate { plan.startingBitRate = cap; plan.reason += "+start-cap" }
        }
        let next = items.indices.contains(activeIndex + 1) ? resolutions.cached(items[activeIndex + 1]) : nil
        // An admitted head still in flight owns the next item until it lands, even once the plan
        // resumes: the native-preroll rule below would cancel it, and other prefixes would take
        // its capacity. In flight starts when the head is issued, before the transport takes the
        // command. On a fast link the next item's pool player may start and join the head. A next
        // item with nothing fetched (after a warm start the plan resumes at once) gets its head first.
        let pair = next.map { item.id + "|" + $0.id } ?? ""
        let headLoading = admitted.map { $0 == next && headPair == pair && proxy?.isPrefetching($0) == true } ?? false
        let headDue = HMPlaybackPriority.headDue(admitted: admitted != nil && admitted == next, issued: headPair == pair,
                                                 cachedBytes: admitted.map { proxy?.cachedByteCount(for: $0) ?? 0 } ?? 0)
        if admitted != nil && (plan.paused || headLoading || headDue) { plan.reason += "+next-head" }
        if plan.paused && !plan.reason.contains("buffer-safety") && !plan.reason.contains("stall") {
            plan.reason += inputs.isStalling ? "+stall" : "+buffer-safety"
        }
        plan = plan.clamped(to: configuration)
        let changed = prefetchPlan != plan
        let bitrateChanged = pool.configuration.startupPeakBitRate != plan.startingBitRate
        let recovered = !prefetchSafe && !plan.paused
        prefetchSafe = !plan.paused
        if changed {
            prefetchPlan = plan
            analytics.recordPrefetchDecision(inputs: inputs, plan: plan, item: item,
                policy: configuration.adaptive ? String(reflecting: type(of: prefetchPolicy)) : "fixed")
            var effective = configuration; effective.startupPeakBitRate = plan.startingBitRate
            pool.configuration = effective; pool.applyConfiguration()
            if bitrateChanged { for node in pool.nodes { node.applyStartingBitRate(plan.startingBitRate) } }
        }
        let deferred = inputs.elapsedOnItemSeconds < plan.startAfterSeconds
        // The next decoder needs only a small head. Do not make it wait for the
        // three-second bulk-prefix recovery threshold after a displayed frame.
        // On a measured slow link, active playback keeps the entire bandwidth.
        let nextNode = next.flatMap { pool.existingNode(for: $0) }
        let earlyNext = configuration.strategy == .S3 && (prefetchPolicy is HMAdaptivePrefetchPolicy || !configuration.adaptive) && !playbackUrgent && !deferred &&
            HMNextWarmSafety.isSafe(ahead: node.snapshot.bufferedAhead, remaining: inputs.remainingSeconds,
                stalling: inputs.isStalling, slow: measurements.throughput.map { $0 < nonnegative(t.slowBytesPerSecond) } ?? false,
                wasWarm: nextNode != nil)
        let warmOffsets = (plan.keepReadyPlayer || earlyNext) && !deferred ? configuration.warmOffsets : []
        let warmItems = warmOffsets.compactMap { offset -> HMMediaItem? in
            let i = activeIndex + offset
            guard items.indices.contains(i), !terminalFailures.contains(identity(items[i])) else { return nil }
            return resolutions.cached(items[i])
        }
        // Startup urgency holds existing neighbours; it only blocks NEW loads.
        // In particular, a back-swipe must retain the page we just left. S2 is
        // the unchanged warm-player control, exempt from the urgency gate.
        let retainedWarm = playbackUrgent ? configuration.warmOffsets.compactMap { offset -> HMMediaItem? in
            let i = activeIndex + offset
            return items.indices.contains(i) ? resolutions.cached(items[i]).flatMap { pool.existingNode(for: $0)?.item } : nil
        } : []
        let previous = configuration.strategy == .S3 && configuration.poolSize >= 3 && activeIndex > 0 ?
            resolutions.cached(items[activeIndex - 1]).flatMap { pool.existingNode(for: $0)?.item } : nil
        pool.trim(keeping: Set([resolutions.cached(item), previous].compactMap { $0 } + warmItems + retainedWarm))
        // Below the fast tier the pool player's own requests slow the head it would join, so it
        // waits for the head to land there (the measured state that lowers the start cap). At the
        // fast tier it waits until the transport runs the head; `prefetch_work: started` decides again.
        let headRunning = headLoading && next.map { proxy?.isPrefetchRunning($0) == true } ?? false
        let nextMayStart = HMPlaybackPriority.nextPlayerMayStart(headDue: headDue, headLoading: headLoading,
                                                                 headRunning: headRunning, fastTier: !startCapLowered)
        for item in warmItems where !playbackUrgent && (item == next ? nextMayStart : !headLoading && !headDue) &&
            pool.existingNode(for: item) == nil {
            // Do not start a fresh previous decoder alongside N+1's preroll.
            if configuration.strategy == .S3, item != next,
               next.flatMap({ pool.existingNode(for: $0) })?.isWaitingForWarmFrame(at: now) == true { continue }
            let warm = pool.node(for: item, protecting: Set([currentItem?.id, next?.id].compactMap { $0 }), playbackURL: proxy?.url(for: item))
            warm.onBufferChanged = { [weak self] in self?.updatePrefetch() }; warm.setMuted(isMuted)
        }
        if plan.paused || deferred || headLoading || headDue {
            if let admitted, !deferred || headLoading {
                if recovered { refreshWindowAfterTransport() }
                headPair = item.id + "|" + admitted.id
                // The plan's own per-item budget, so the full plan that follows keeps this transfer.
                var head = plan
                head.paused = false; head.itemsAhead = 1; head.itemsBehind = 0; head.keepReadyPlayer = false; head.concurrency = 1
                head = head.clamped(to: configuration)
                let headIdentity = "next-head|" + head.workIdentity + "|" + item.id + "|" + admitted.id +
                    (admitted.url.map { HMCacheKey.canonical($0, ignoring: configuration.volatileSigningQueryParameters) } ?? "")
                guard headIdentity != prefetchIdentity else { return }
                prefetchIdentity = headIdentity
                // A pause still stops every other prefix.
                proxy?.cancelPrefetch(sparing: admitted)
                proxy?.prefetch([admitted], keeping: mediaWindowItems.compactMap { resolutions.cached($0) }, plan: head)
                return
            }
            if !prefetchIdentity.isEmpty { proxy?.cancelPrefetch(); prefetchIdentity = "" }
            headPair = ""
            if recovered && !plan.paused { refreshWindowAfterTransport() }
            return
        }
        headPair = ""
        let data = plan.windowOffsets.compactMap { offset -> HMMediaItem? in
            let i = activeIndex + offset; return items.indices.contains(i) ? resolutions.cached(items[i]) : nil
        }.filter { !warmItems.contains($0) }
        // Native preroll owns N+1's head; never download it a second time via
        // explicit prefetch or let N+2 steal capacity before N+1 is ready.
        if let next, warmItems.contains(next), pool.existingNode(for: next)?.isWaitingForWarmFrame(at: now) == true {
            if !prefetchIdentity.isEmpty { proxy?.cancelPrefetch(); prefetchIdentity = "" }
            return
        }
        let mediaKeys = data.map { entry in
            entry.id + (entry.url.map { HMCacheKey.canonical($0, ignoring: configuration.volatileSigningQueryParameters) } ?? "")
        }.joined(separator: "|")
        let windowIdentity = plan.workIdentity + "|" + item.id + "|" + mediaKeys
        guard windowIdentity != prefetchIdentity else { if recovered { refreshWindowAfterTransport() }; return }
        prefetchIdentity = windowIdentity
        proxy?.prefetch(data, keeping: mediaWindowItems.compactMap { resolutions.cached($0) }, plan: plan)
        if recovered { refreshWindowAfterTransport() }
    }
    /// The next item, when its prefix may load while the plan holds the rest
    /// (HMPlaybackPriority.admitsNextHead). A pool player already holding it keeps its own load.
    private func admittedNext(rebuffering: Bool = false) -> HMMediaItem? {
        let node = currentNode
        let displayed = node?.isActive == true && node?.snapshot.timeToFirstFrame != nil
        guard configuration.strategy.usesDataCache, configuration.prefetch.ahead > 0,
              items.indices.contains(activeIndex + 1), !terminalFailures.contains(identity(items[activeIndex + 1])),
              let next = resolutions.cached(items[activeIndex + 1]), let url = next.url, !url.isFileURL else { return nil }
        // A prefix in flight (or issued, not yet started) keeps the next item: its pool player's reads join that download.
        let inFlight = proxy?.isPrefetching(next) == true
        guard (!configuration.adaptive || HMPlaybackPriority.admitsNextHead(displayed: displayed, warmStart: node?.playbackSnapshot.readinessTier == .warmPlayer,
                  rebuffering: rebuffering, dwell: measurements.dwell, bingeDwell: configuration.adaptiveThresholds.bingeDwellSeconds,
                  inFlight: inFlight)),
              inFlight || pool.existingNode(for: next) == nil else { return nil }
        return next
    }
    private func updateInteractions() {
        let current = isFeedVisible ? currentItem : nil
        let next = isFeedVisible && currentItem != nil && items.indices.contains(activeIndex + 1) ? items[activeIndex + 1] : nil
        let keep = Set([current, next].compactMap { $0 })
        for item in Set([interactionCurrent, interactionNext].compactMap { $0 }) where !keep.contains(where: { $0.hasSameMedia(as: item, ignoring: configuration.volatileSigningQueryParameters) }) { interactions.didLeave(item) }
        if current?.mediaIdentity(ignoring: configuration.volatileSigningQueryParameters) != interactionCurrent?.mediaIdentity(ignoring: configuration.volatileSigningQueryParameters), let current { interactions.didBecomeCurrent(current) }
        if next?.mediaIdentity(ignoring: configuration.volatileSigningQueryParameters) != interactionNext?.mediaIdentity(ignoring: configuration.volatileSigningQueryParameters), let next { interactions.willBecomeNext(next) }
        interactionCurrent = current; interactionNext = next
    }
    /// Read-only playback snapshot for an entry. Unprepared entries report idle.
    ///
    /// Access on the main actor.
    public func snapshot(for item: HMMediaItem) -> HMPlaybackSnapshot {
        var value = resolutions.cached(item).flatMap { pool.existingNode(for: $0) }?.playbackSnapshot ??
            (currentItem?.hasSameMedia(as: item, ignoring: configuration.volatileSigningQueryParameters) == true ? pendingSnapshot : HMPlaybackSnapshot())
        if value.aspectRatio == nil { value.aspectRatio = item.aspectRatio }
        return value
    }
    /// Clock-indexed overlay data. Network session lifecycle belongs to the interaction hooks, not this accessor.
    ///
    /// Access on the main actor.
    public func timeline(for item: HMMediaItem) -> HMStreamTimeline {
        // Outside the playlist: the inert engagement's empty timeline, not a fresh source call per body pass.
        guard let entry = entry(withID: item.id) else { return detachedEngagement(for: item).timeline }
        if let existing = timelines[entry] { return existing }
        let created = interactions.timeline(for: resolutions.cached(entry) ?? entry); timelines[entry] = created; return created
    }
    /// Observable chat, polls, reactions and actions for an entry, on its media clock; actions default
    /// to the entry's current playback time. Kept while the entry is near the playhead, or anywhere in
    /// the playlist once the viewer has acted in it; otherwise rebuilt (and `engagementDidLoad` called
    /// again) when it comes back. An item that isn't in the playlist gets an inert, empty engagement.
    /// Bounded deletion records are kept separately per item ID until playlist removal or teardown,
    /// so rebuilt engagements cannot restore moderated events or polls.
    ///
    /// Access on the main actor.
    public func engagement(for item: HMMediaItem) -> HMEngagement {
        guard let entry = entry(withID: item.id) else { return detachedEngagement(for: item) }
        if let existing = engagements[entry] { return existing }
        let display = resolutions.cached(entry) ?? resolutions.cached(entry, requireFormat: false) ?? entry
        // Deletion records outlive this cache entry, but never outlive the playlist item.
        let moderation = moderationByItemID[entry.id] ?? HMModerationState(itemID: entry.id)
        moderationByItemID[entry.id] = moderation
        // The player owns the source; its engagements borrow it.
        let created = HMEngagement(item: display, timeline: timeline(for: entry), source: interactions,
                                   retainsSource: false, moderation: moderation) { [weak self] in
            self?.snapshot(for: entry).currentTime ?? 0
        }
        engagements[entry] = created
        interactions.engagementDidLoad(created)
        return created
    }
    var cachedEngagementCount: Int { engagements.count }
    var cachedTimelineCount: Int { timelines.count }
    private func detachedEngagement(for item: HMMediaItem) -> HMEngagement {
        if let existing = detachedEngagements[item.id] { return existing }
        if detachedEngagements.count >= 8 { detachedEngagements.removeAll() }
        let inert = HMEngagement(item: item, timeline: HMEmptyTimeline(duration: item.durationHint ?? 0), source: nil,
                                 retainsSource: false, capabilities: .readOnly, polls: [])
        detachedEngagements[item.id] = inert
        return inert
    }
    private func entry(withID id: String) -> HMMediaItem? {
        if idIndexVersion != itemsVersion {
            idIndex = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            idIndexVersion = itemsVersion
        }
        guard let index = idIndex[id], items.indices.contains(index), items[index].id == id else { return nil }
        return items[index]
    }
    var currentNode: HMPlayerNode? { currentItem.flatMap { resolutions.cached($0) }.flatMap { pool.existingNode(for: $0) } }
    func node(for item: HMMediaItem) -> HMPlayerNode? { resolutions.cached(item).flatMap { pool.existingNode(for: $0) } }
    func displayItem(_ item: HMMediaItem) -> HMMediaItem { resolutions.cached(item, requireFormat: false) ?? item }
    /// Toggles current playback; useful for tap overlays.
    ///
    /// Access on the main actor.
    public func togglePlayPause() { wantsPlayback ? pause() : play() }
    /// Toggles global mute.
    ///
    /// Access on the main actor.
    public func toggleMute() { isMuted.toggle() }
    /// Seeks to a fraction of the current VOD duration.
    ///
    /// Access on the main actor.
    public func seek(toProgress progress: Double) { guard progress.isFinite else { report(.invalidSeek); return }; seek(to: snapshot.duration * min(1, max(0, progress))) }
    private func pauseAll() {
        proxy?.setProgressAllowed(false); prefetchSafe = false
        for node in pool.nodes where node.isActive { node.pause() }; adNode?.pause()
        resolutionRetryTask?.cancel(); resolutionRetryTask = nil
        networkRetryTask?.cancel(); networkRetryTask = nil
        // Visibility pauses media work, but in-flight URL/poster resolution survives.
        updateInteractions()
    }
    /// Ends a benchmark session, drains transport accounting and emits runEnd. The player is terminal afterwards.
    @_spi(Benchmark) public func finishRun() async {
        guard !ended else { return }
        isFullscreen = false
        ended = true; stopWork()
        let item = currentItem
        for node in pool.nodes { node.release() }
        await transportTask?.value
        let waste = await proxy?.finish() ?? 0
        if let item { analytics.emit(HMPlaybackEvent(kind: .runEnd, itemID: item.id, metrics: ["wasted_prefetch_bytes": Double(waste)]), item: item) }
        finishSubscribers()
    }
    /// Releases players, interaction sessions and asynchronous work. Call when the host is permanently dismissed.
    ///
    /// Access on the main actor.
    public func teardown() {
        isFullscreen = false
        ended = true; stopWork()
        if let proxy { Task { _ = await proxy.finish() } }
        for node in pool.nodes { analytics.detach(playerKey: node.id) }; pool.releaseAll()
        finishSubscribers()
        engagements.removeAll(); detachedEngagements.removeAll(); timelines.removeAll(); moderationByItemID.removeAll()
        if configuration.managesAudioSession && didActivateAudioSession { HMAudioSession.deactivate(); didActivateAudioSession = false }
    }
    private func stopWork() {
        setDiagnostics(nil)
        mediaResetPosition = nil
        captionObserver?.cancel(); captionObserver = nil
        #if os(iOS)
        audioObserver?.cancel(); audioObserver = nil
        #endif
        if adState.isActive { endAd(.cancelled, resume: false) }
        failureAdvanceTask?.cancel(); failureAdvanceTask = nil
        interactionTimeoutTask?.cancel(); interactionTimeoutTask = nil
        networkRetryTask?.cancel(); networkRetryTask = nil
        connectivityMonitor?.cancel(); connectivityMonitor = nil
        pageGeneration += 1; loadTask?.cancel(); isLoadingPage = false
        pagingRetryTask?.cancel(); pagingRetryTask = nil
        resolutionRetryTask?.cancel(); resolutionRetryTask = nil
        resolutions.cancelAll(); for task in resolutionTasks.values { task.cancel() }; resolutionTasks.removeAll(); resolutionTaskTokens.removeAll()
        for item in Set([interactionCurrent, interactionNext].compactMap { $0 }) { interactions.didLeave(item) }
        interactionCurrent = nil; interactionNext = nil; proxy?.cancelPrefetch()
    }
    // Ad work is visit-scoped, independently cancelled, and never changes the content clock.
    private func consultAdIfNeeded() {
        guard isFeedVisible, !ended, let item = currentItem, adVisit != identity(item) else { return }
        adVisit = identity(item)
        guard let provider = adBreakProvider else { return }
        adToken = UUID(); let token = adToken
        adItem = item; adDecisionPending = true; adDidStart = false; adProgress = HMAdProgress(); adContentOutcome = nil
        setAdState(.loading)
        proxy?.cancelPrefetch(); prefetchIdentity = ""; prefetchSafe = false
        emit(.adPrefetchChanged(paused: true))
        analytics.emit(HMPlaybackEvent(kind: .adPrefetchChanged, itemID: item.id, properties: ["paused": "true"]), item: item)
        adTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Self.adTimeout(self?.configuration.adDecisionTimeout, fallback: 1, range: 0.05...10))) } catch { return }
            guard let self, self.adToken == token, self.adDecisionPending else { return }
            self.endAd(.timedOut)
        }
        // Unstructured deliberately: an uncooperative SDK decision cannot hold a task-group scope open.
        adDecisionTask = Task { [weak self] in
            do {
                let decision = try await provider.adBreak(for: item)
                guard let self, self.adToken == token, self.adState.isActive, !Task.isCancelled else {
                    if case .hostPlayed(let host) = decision { host.stop(.cancelled) }
                    return
                }
                self.adDecisionPending = false; self.adTimeoutTask?.cancel(); self.adTimeoutTask = nil
                switch decision {
                case .none: self.endAd(.noFill)
                case .preRoll(let ad): self.startURLAd(ad, token: token)
                case .hostPlayed(let host): self.startHostAd(host, token: token)
                }
            } catch {
                guard let self, self.adToken == token, self.adState.isActive else { return }
                self.endAd(.failed)
            }
        }
    }
    private static func adTimeout(_ value: TimeInterval?, fallback: TimeInterval, range: ClosedRange<Double>) -> Double {
        guard let value, value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
    private func setAdState(_ state: HMAdState) {
        guard state != adState else { return }
        adState = state
        if state.isActive { diagnosticsRecorder?.cancelDelivery() }
        if let item = adItem {
            emit(.adStateChanged(item: item, state: state))
            analytics.emit(HMPlaybackEvent(kind: .adStateChanged, itemID: item.id, properties: Self.adStateProperties(state)), item: item)
        }
    }
    private static func adStateProperties(_ state: HMAdState) -> [String: String] {
        switch state {
        case .none: return ["state": "none"]
        case .loading: return ["state": "loading"]
        case .playing(let kind): return ["state": "playing", "kind": kind.rawValue]
        case .finished: return ["state": "finished"]
        }
    }
    private func updateHostPlaybackPermission() {
        proxy?.setProgressAllowed(mediaProgressAllowed)
        // Paused time is not evidence of a stuck SDK; the wall-clock cap still applies.
        adLastProgressAt = ProcessInfo.processInfo.systemUptime
        hostAdContext?.setPlaybackAllowed(isFeedVisible && playbackAllowed && adState.isActive)
    }
    private func updateAdProgress(_ value: HMAdProgress) {
        if value.elapsed != adProgress.elapsed { adLastProgressAt = ProcessInfo.processInfo.systemUptime }
        adProgress = value
    }
    private func beginAcceptedAd(token: UUID) {
        resetAdContentPosition(); adDidStart = true; wantsPlayback = true
        let started = ProcessInfo.processInfo.systemUptime
        adLastProgressAt = started
        let cap = Self.adTimeout(configuration.adBreakMaxDuration, fallback: 120, range: 0.1...3600)
        let idle = Self.adTimeout(configuration.adNoProgressTimeout, fallback: 10, range: 0.1...120)
        adWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let self, self.adToken == token, self.adState.isActive else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if !self.isFeedVisible || !self.playbackAllowed { self.adLastProgressAt = now }
                let stuck = self.adState != .loading && now - self.adLastProgressAt >= idle
                if now - started >= cap || stuck { self.endAd(.timedOut); return }
            }
        }
    }
    private func startHostAd(_ host: HMHostAdBreak, token: UUID) {
        beginAcceptedAd(token: token)
        hostBreak = host
        let context = HMHostAdContext(finish: { [weak self] outcome in
            guard let self, self.adToken == token else { return }; self.endAd(outcome)
        }, progress: { [weak self] progress in
            guard let self, self.adToken == token, self.adState.isActive else { return }
            self.updateAdProgress(progress)
        })
        hostAdContext = context
        context.setPlaybackAllowed(isFeedVisible && playbackAllowed)
        setAdState(.playing(kind: .host))
        host.start(context)
    }
    private func startURLAd(_ ad: HMMediaItem, token: UUID) {
        beginAcceptedAd(token: token)
        guard let url = ad.url, ["file", "http", "https"].contains(url.scheme?.lowercased() ?? "") else { endAd(.failed); return }
        var config = configuration; config.loops = false; config.restoresPlaybackPosition = false
        let node = HMPlayerNode(id: "hm-ad-" + token.uuidString, configuration: config)
        adNode = node; node.setMuted(isMuted)
        node.onEvent = { [weak self, weak node] event, _ in
            guard let self, let node, self.adToken == token else { return }
            switch event.kind {
            case .firstFrame:
                self.adTimeoutTask?.cancel(); self.adTimeoutTask = nil
                self.updateAdProgress(HMAdProgress(elapsed: node.snapshot.currentTime, duration: node.snapshot.duration))
                self.setAdState(.playing(kind: .player))
            case .ended: self.endAd(.completed)
            case .error: self.endAd(.failed)
            default: break
            }
        }
        // Use the same AVFoundation engine; leave content's native assignment untouched.
        node.warm(with: ad)
        node.activate(requestedAt: ProcessInfo.processInfo.systemUptime, reason: "ad", cachedBytes: 0)
        if !isFeedVisible || !playbackAllowed { node.pause() }
        adTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Self.adTimeout(config.adLoadTimeout, fallback: 5, range: 0.1...30))) } catch { return }
            guard let self, self.adToken == token, self.adState == .loading else { return }; self.endAd(.timedOut)
        }
        adProgressTask = Task { [weak self, weak node] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard let self, let node, self.adToken == token, self.adState.isActive else { return }
                if case .playing = self.adState { self.updateAdProgress(HMAdProgress(elapsed: node.snapshot.currentTime, duration: node.snapshot.duration)) }
            }
        }
    }
    /// Calls the host adapter's stop callback or ends the URL ad. Host decides when skip is offered.
    public func skipAd() { if adState.isActive { endAd(.skipped) } }
    private func endAd(_ outcome: HMAdOutcome, resume: Bool = true) {
        guard adState.isActive else { return }
        adToken = UUID(); adDecisionPending = false
        adContentOutcome = adDidStart ? outcome : nil
        adWatchdogTask?.cancel(); adWatchdogTask = nil
        adDecisionTask?.cancel(); adDecisionTask = nil
        adTimeoutTask?.cancel(); adTimeoutTask = nil
        adProgressTask?.cancel(); adProgressTask = nil
        let host = hostBreak; hostBreak = nil
        hostAdContext?.invalidate(); hostAdContext = nil
        adNode?.onEvent = nil; adNode?.release(); adNode = nil
        setAdState(.finished)
        if let item = adItem {
            emit(.adBreakEnded(item: item, outcome: outcome))
            analytics.emit(HMPlaybackEvent(kind: .adBreakEnded, itemID: item.id, properties: ["outcome": outcome.rawValue]), item: item)
            analytics.emit(HMPlaybackEvent(kind: .adPrefetchChanged, itemID: item.id, properties: ["paused": "false"]), item: item)
        }
        emit(.adPrefetchChanged(paused: false)); adItem = nil
        host?.stop(outcome)
        prefetchIdentity = ""; lastDecisionAt = -Double.infinity
        if resume, !ended {
            if adDidStart && (outcome == .completed || outcome == .skipped) { requestTime = ProcessInfo.processInfo.systemUptime }
            refreshWindow(); scheduleFailedItemAdvance()
        }
    }
    private func resetAdContentPosition() {
        if let item = currentItem { resumePositions[identity(item)] = nil }
        if let node = currentNode, node.snapshot.currentTime > 0.01 { node.resetForAd() }
    }
    private func prepareAdHeads() {
        guard isFeedVisible, !ended, adState.isActive else { return }
        // Preroll the active content at zero, and protect the next head even while bulk work is paused.
        if let current = currentItem.flatMap({ resolutions.cached($0) }) { proxy?.prioritizePlayback(current, urgent: false) }
        guard configuration.poolSize > 1, configuration.prefetch.ahead > 0, items.indices.contains(activeIndex + 1),
              let next = resolutions.cached(items[activeIndex + 1]), pool.existingNode(for: next) == nil else { return }
        // Never recycle an existing neighbour for speculative work during an ad decision/break.
        guard pool.nodes.contains(where: { $0.item == nil }) else { return }
        let node = pool.node(for: next, protecting: Set(pool.nodes.compactMap { $0.item?.id }), playbackURL: proxy?.url(for: next))
        node.setMuted(isMuted)
    }

    private func finishSubscribers() { for continuation in subscribers.values { continuation.finish() }; subscribers.removeAll() }
    private func applyConfiguration() {
        guard !ended else { return }
        if !configuration.managesAudioSession { didActivateAudioSession = false }
        if resolutionSigningParameters != configuration.volatileSigningQueryParameters {
            for task in resolutionTasks.values { task.cancel() }
            resolutionTasks.removeAll(); resolutionTaskTokens.removeAll()
            resolutionFailures.removeAll(); networkFailures.removeAll(); terminalFailures.removeAll()
            resumePositions.removeAll(); mediaResetPosition = nil
            resolutionSigningParameters = configuration.volatileSigningQueryParameters
        }
        resolutions.configure(signingParameters: configuration.volatileSigningQueryParameters)
        var effective = configuration
        if let plan = prefetchPlan { effective.startupPeakBitRate = plan.clamped(to: configuration).startingBitRate }
        pool.configuration = effective
        for node in pool.nodes.dropFirst(max(1, min(4, configuration.poolSize))) { analytics.detach(playerKey: node.id) }
        pool.resize(to: configuration.poolSize); proxy?.configuration = configuration; prefetchSafe = false
        prefetchIdentity = ""; lastDecisionAt = -Double.infinity
        refreshWindow(); checkEnd(); scheduleFailedItemAdvance()
    }
    private func handle(_ event: HMPlaybackEvent, item: HMMediaItem) {
        if let recorder = diagnosticsRecorder {
            switch event.kind {
            case .viewStart:
                recorder.cancelDelivery(); recorder.record(.attempt, at: event.monotonicTime)
            case .firstFrame: recorder.record(.firstFrame(event.metrics["ttff_ms"] ?? .nan), at: event.monotonicTime)
            case .viewEnd:
                // Resize/trim clear assignments before synchronous release emits viewEnd.
                if let key = event.properties["player_key"],
                   let emitting = pool.nodes.first(where: { $0.id == key }),
                   emitting.snapshot.timeToFirstFrame == nil {
                    recorder.record(.endedBeforeFrame, at: event.monotonicTime)
                }
            case .rebufferStart: recorder.cancelDelivery()
            case .rebufferEnd: recorder.record(.stall(event.metrics["stall_ms"] ?? .nan), at: event.monotonicTime)
            case .playing:
                if let ms = event.metrics["first_moving_playback_ms"] { recorder.record(.moving(ms), at: event.monotonicTime) }
            default: break
            }
        }
        if event.kind == .playing, event.metrics["first_moving_playback_ms"] != nil {
            if event.properties["activation_id"] == currentNode?.snapshot.activationID {
                playedActivationID = event.properties["activation_id"] ?? ""
            }
            analytics.recordBenchmark(event, item: item); updatePrefetch(force: true)
            return
        }
        if event.kind == .transferSample {
            measurements.transfer(bytes: event.metrics["sample_bytes"] ?? 0, seconds: event.metrics["receive_s"] ?? 0,
                ttfb: event.metrics["ttfb_s"], alpha: configuration.adaptiveThresholds.ewmaAlpha)
        }
        let nextArrival = event.kind == .viewStart && arrivalDwell != nil
        if event.kind == .viewStart {
            if let dwell = arrivalDwell {
                measurements.arrival(hit: ["warmPlayer", "cachedBytes"].contains(event.properties["readiness_tier"] ?? ""),
                    dwell: dwell, alpha: configuration.adaptiveThresholds.ewmaAlpha)
            }
            arrivalDwell = nil; activatedAt = event.monotonicTime; lastDecisionAt = -Double.infinity
        }
        var metrics = event.metrics
        if event.kind == .viewStart {
            metrics["next_arrival"] = nextArrival ? 1 : 0
            metrics["ready_by_swipe_hit"] = ["warmPlayer", "cachedBytes"].contains(event.properties["readiness_tier"] ?? "") ? 1 : 0
        }
        if event.kind == .viewStart || event.kind == .firstFrame { metrics["live_player_count"] = Double(pool.nodes.count); metrics["memory_bytes"] = HMMemorySample.footprint() }
        var properties = event.properties
        if event.kind == .viewStart || event.kind == .firstFrame {
            properties["after_ad"] = adContentOutcome == nil ? "false" : "true"
            if let outcome = adContentOutcome { properties["ad_outcome"] = outcome.rawValue }
        }
        analytics.emit(HMPlaybackEvent(kind: event.kind, itemID: event.itemID, timestamp: event.timestamp,
            monotonicTime: event.monotonicTime, position: event.position, metrics: metrics, properties: properties), item: item)
        let entry = entry(withID: item.id) ?? item
        switch event.kind {
        case .ended:
            if playlist.finishingID == item.id, currentItem?.id == item.id {
                mutate { $0.remove(ids: [item.id]) }
            }
        case .preloadReady:
            networkFailures[identity(entry)] = nil
            emit(.itemReady(entry))
        case .firstFrame:
            emit(.firstFrame(entry, ttff: (event.metrics["ttff_ms"] ?? 0) / 1000, readiness: currentNode?.snapshot.readinessTier ?? .cold))
            updatePrefetch(force: true)
        case .playing:
            if currentNode?.hasStartedMoving == true, let id = event.properties["activation_id"], id == currentNode?.snapshot.activationID { playedActivationID = id }
            updatePrefetch(force: true)
        case .transfer where ["started", "completed"].contains(event.properties["prefetch_work"] ?? ""):
            updatePrefetch(force: true)
        case .rebufferStart: emit(.stallStarted(entry)); updatePrefetch(force: true)
        case .rebufferEnd: emit(.stallEnded(entry)); updatePrefetch(force: true)
        case .error, .transportError:
            if event.properties["native_direct_fallback"] == "origin-range-unsupported" {
                pool.existingNode(for: item)?.retryDirectTransport(for: item)
                return
            }
            report(.playback(event.properties["error_message"] ?? event.properties["message"] ?? "Playback failed"), item: entry)
            // Transport errors can recover via the node's direct-URL fallback.
            // Only the native terminal error marks the entry unplayable.
            if event.kind == .error, resolutions.cached(entry)?.hasSameMedia(as: item, ignoring: configuration.volatileSigningQueryParameters) == true {
                let raw = NSError(domain: event.properties["error_domain"] ?? "", code: Int(event.properties["error_code"] ?? "") ?? 0)
                if event.properties["transient_network"] == "true" || HMNetworkFailure.isTransient(raw) {
                    markNetworkFailure(entry)
                } else { markTerminalFailure(entry) }
            }
        default: break
        }
    }
    /// While an error is transient, only current and next retry. Farther window entries keep their
    /// failure record and retry once navigation brings them into this pair, so a recovering server
    /// sees at most two requests per client rather than the whole prefetch window at once.
    private var networkRetryTargets: Set<HMMediaItem.MediaIdentity> {
        guard !failureIdle, let currentItem else { return [] }
        return Set(([currentItem] + (items.indices.contains(activeIndex + 1) ? [items[activeIndex + 1]] : [])).map(identity))
    }
    private func advanceRemovedFailureIfNeeded() {
        guard let id = playlist.finishingID, effectiveRemovedCurrentPolicy == .advanceNow else { return }
        mutate { $0.remove(ids: [id]) }
    }
    private func markNetworkFailure(_ item: HMMediaItem) {
        terminalFailures.remove(identity(item))
        var retry = networkFailures[identity(item)] ?? HMNetworkRetry()
        retry.failed(at: ProcessInfo.processInfo.systemUptime)
        networkFailures[identity(item)] = retry
        advanceRemovedFailureIfNeeded(); scheduleNetworkRetry()
    }
    private func scheduleNetworkRetry() {
        networkRetryTask?.cancel(); networkRetryTask = nil
        guard !ended, isFeedVisible else { return }
        let targets = networkRetryTargets
        guard let deadline = networkFailures.filter({ targets.contains($0.key) }).values.map(\.nextAttempt).filter(\.isFinite).min() else { return }
        networkRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.01, deadline - ProcessInfo.processInfo.systemUptime))) } catch { return }
            self?.retryNetworkFailures()
        }
    }
    private func retryNetworkFailures() {
        guard !ended, isFeedVisible else { return }
        let now = ProcessInfo.processInfo.systemUptime, targets = networkRetryTargets
        for key in Array(networkFailures.keys) where targets.contains(key) && networkFailures[key]!.nextAttempt <= now {
            networkFailures[key]?.nextAttempt = .infinity
            guard let item = items.first(where: { identity($0) == key }) else { continue }
            if let node = node(for: item), node.snapshot.state == .failed {
                node.release()
                if currentItem?.hasSameMedia(as: item, ignoring: configuration.volatileSigningQueryParameters) == true { pendingSnapshot.state = .loading }
            }
        }
        refreshWindow()
    }
    // Called by the owned NWPathMonitor; internal for deterministic reconnect coverage.
    func connectivityChanged(satisfied: Bool) {
        guard !ended else { return }
        let returned = lastPathSatisfied == false && satisfied
        lastPathSatisfied = satisfied
        guard returned else { return }
        terminalFailures.removeAll(); resolutionFailures.removeAll()
        for key in Array(networkFailures.keys) { networkFailures[key]?.nextAttempt = 0 }
        if failureIdle, playlist.current != nil {
            failureIdle = false; pendingSnapshot = HMPlaybackSnapshot(); pendingSnapshot.state = .loading
            emit(.currentItemChanged(currentItem))
        }
        if currentNode?.snapshot.state == .failed { currentNode?.release() }
        retryNetworkFailures()
    }
    private func markTerminalFailure(_ item: HMMediaItem) {
        networkFailures[identity(item)] = nil
        terminalFailures.insert(identity(item))
        advanceRemovedFailureIfNeeded(); scheduleFailedItemAdvance()
    }
    private func scheduleFailedItemAdvance() {
        guard !ended, failureAdvanceTask == nil else { return }
        failureAdvanceTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            failureAdvanceTask = nil
            advancePastFailure()
        }
    }
    private func advancePastFailure() {
        guard !adState.isActive, !isFullscreen else { return }
        if let deferred = deferredFailureCommit, !isInteracting {
            deferredFailureCommit = nil
            commitPage(toID: deferred.id, requestedAt: ProcessInfo.processInfo.systemUptime)
            return
        }
        guard !ended, configuration.failedItemPolicy == .skip, !isInteracting, !pageIsMoving,
              requestedPageID == nil, let failed = currentItem ?? (failureIdle ? playlist.current : nil),
              terminalFailures.contains(identity(failed)) else { return }
        let index = playlist.index
        let forward = Array(items.indices.dropFirst(index + 1))
        // A late page may contain the next playable entry; do not retreat while it is outstanding.
        // Once the paging retry budget is exhausted no page is coming without navigation or an
        // explicit loadNextPage(), so fall back to the previous entry instead of waiting forever.
        if !forward.contains(where: { !terminalFailures.contains(identity(items[$0])) }), isLoadingPage || (hasMoreContent && !pagingRetry.exhausted) {
            checkEnd()
            return
        }
        let candidates = forward + Array(items.indices.prefix(index).reversed())
        guard let next = candidates.first(where: { !terminalFailures.contains(identity(items[$0])) }) else {
            guard !failureIdle else { return }
            saveAndDeactivate(); failureIdle = true; pendingSnapshot = HMPlaybackSnapshot()
            proxy?.cancelPrefetch(); pool.releaseAll(); refreshWindow()
            emit(.currentItemChanged(nil))
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if feedSurfaces > 0, !failureIdle {
            requestPage(at: next); failurePageID = items[next].id
        } else {
            failurePageID = items[next].id
            commitPage(toID: items[next].id, requestedAt: now)
        }
    }
    private func emit(_ event: HMPlayerEvent) {
        lastEvent = event; for continuation in subscribers.values { continuation.yield(event) }
        // Every current change passes here; engine assignments and route changes arrive from the node.
        if case .currentItemChanged(_) = event { syncExternalPlayback() }
    }
    /// Reads the route of the engine carrying current content; false while idle or after teardown.
    private func syncExternalPlayback() {
        let active = !ended && (externalPlaybackOverride ?? (currentNode?.isExternalPlaybackActive == true))
        guard active != isExternalPlaybackActive else { return }
        isExternalPlaybackActive = active
        emitExternalPresentation()
    }
    private func emitExternalPresentation() {
        emit(.externalPresentationChanged(pictureInPicture: isPictureInPictureActive, externalPlayback: isExternalPlaybackActive))
    }
    private func report(_ kind: HMPlayerError, item: HMMediaItem? = nil) { loadError = kind.localizedDescription; emit(.error(item: item, kind: kind)) }
}
#endif
