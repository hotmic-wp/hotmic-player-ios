#if canImport(UIKit) && !os(watchOS)
import SwiftUI
import UIKit

/// iOS 17 bridge: scrollPosition changes during a drag; delegate end callbacks
/// identify the settled page. Forward other delegate messages to SwiftUI.
@MainActor final class HMScrollViewReference {
    weak var scroll: UIScrollView?
    var isRestoringFullscreen = false
    var lastMotionAt: TimeInterval = 0
}

struct HMPageCommitProbe: UIViewRepresentable {
    var itemIDs: [String]
    var currentID: String?
    var targetIndex: Int?
    var isSuspended = false
    var requestID: UUID
    var reference: HMScrollViewReference? = nil
    var interaction: (Bool) -> Void = { _ in }
    var commit: (String, TimeInterval) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(commit: commit, reference: reference, interaction: interaction) }
    func makeUIView(context: Context) -> Probe {
        let view = Probe(); view.coordinator = context.coordinator
        return view
    }
    func updateUIView(_ view: Probe, context: Context) {
        let coordinator = context.coordinator
        coordinator.isSuspended = isSuspended
        coordinator.commit = commit
        coordinator.interaction = interaction
        coordinator.reconcile(items: itemIDs, current: currentID)
        coordinator.reference = reference
        coordinator.targetIndex = targetIndex; coordinator.requestID = requestID
        view.connect()
    }
    static func dismantleUIView(_ view: Probe, coordinator: Coordinator) {
        coordinator.interaction(false)
        coordinator.fallback?.cancel(); coordinator.fallback = nil; coordinator.offsetObservation = nil
        if let scroll = coordinator.scroll, scroll.delegate === coordinator { scroll.delegate = coordinator.original }
    }
    final class Probe: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() { super.didMoveToWindow(); connect() }
        func connect() {
            DispatchQueue.main.async { [weak self] in
                guard let self, window != nil, let coordinator else { return }
                var ancestor = superview
                while let view = ancestor {
                    if let scroll = view as? UIScrollView {
                        coordinator.observe(scroll)
                        if scroll.delegate !== coordinator {
                            coordinator.original = scroll.delegate
                            coordinator.scroll = scroll; scroll.delegate = coordinator
                        }
                        coordinator.pageIfRequested()
                        return
                    }
                    ancestor = view.superview
                }
            }
        }
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var interaction: (Bool) -> Void
        var commit: (String, TimeInterval) -> Void
        var reference: HMScrollViewReference?
        var offsetObservation: NSKeyValueObservation?
        var fallback: DispatchWorkItem?
        private var lastMotionAt: TimeInterval = 0
        func observe(_ view: UIScrollView) {
            reference?.scroll = view
            guard scroll !== view || offsetObservation == nil else { return }
            scroll = view
            offsetObservation = view.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                // UIKit's contentOffset is set on the main thread. Observe it
                // independently of delegate ownership; schedule at most one
                // quiet-period callback, rather than a task on every frame.
                MainActor.assumeIsolated { self?.motionChanged() }
            }
        }
        private func motionChanged() {
            guard !isSuspended else { return }
            interaction(true)
            lastMotionAt = ProcessInfo.processInfo.systemUptime
            reference?.lastMotionAt = lastMotionAt
            scheduleFallback(after: 0.2)
        }
        private func scheduleFallback(after delay: TimeInterval) {
            guard fallback == nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.commitIfQuiet() }
            fallback = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        private func commitIfQuiet() {
            fallback = nil
            guard let scroll, scroll.window != nil, !scroll.isDragging, !scroll.isDecelerating else { return }
            let quiet = ProcessInfo.processInfo.systemUptime - lastMotionAt
            guard quiet >= 0.2 else { scheduleFallback(after: 0.2 - quiet); return }
            // TTFF begins when the page is committed, including for the quiet fallback.
            settled(scroll, time: ProcessInfo.processInfo.systemUptime)
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            motionChanged()
            original?.scrollViewDidScroll?(scrollView)
        }
        private var itemIDs: [String] = []
        private var currentID: String?
        private var anchor: Int = 0
        private var needsReconcile = false
        private var suppressCommit = false
        private var restoringFullscreen = false
        private var pageSize: CGSize?
        private func observePageSize(_ scroll: UIScrollView) {
            guard scroll.bounds.width > 0, scroll.bounds.height > 0 else { return }
            defer { pageSize = scroll.bounds.size }
            guard let pageSize, pageSize != scroll.bounds.size else { return }
            // A host rotation/resize changes the offset-to-page mapping without a swipe.
            // Keep the active-ID anchor through that geometry change as on fullscreen exit.
            restoringFullscreen = true; reference?.isRestoringFullscreen = true
            lastMotionAt = ProcessInfo.processInfo.systemUptime
            fallback?.cancel(); fallback = nil
        }
        var isSuspended = false {
            didSet {
                if isSuspended { restoringFullscreen = true; reference?.isRestoringFullscreen = true; fallback?.cancel(); fallback = nil; interaction(false) }
                else if oldValue { lastMotionAt = ProcessInfo.processInfo.systemUptime }
            }
        }
        func reconcile(items: [String], current: String?) {
            if !itemIDs.isEmpty, items != itemIDs {
                let destination: String?
                if let targetIndex, itemIDs.indices.contains(targetIndex) { destination = itemIDs[targetIndex] }
                else if let scroll, scroll.bounds.height > 0 {
                    let page = (scroll.contentOffset.y + scroll.adjustedContentInset.top) / scroll.bounds.height
                    // Even an early drag has a destination: use its direction,
                    // rather than rounding it back to the current page.
                    let oldAnchor = currentID.flatMap { itemIDs.firstIndex(of: $0) } ?? anchor
                    let index = Int(page > Double(oldAnchor) ? ceil(page) : floor(page))
                    destination = itemIDs.indices.contains(index) ? itemIDs[index] : nil
                } else { destination = nil }
                if !HMPagePosition.survives(old: itemIDs, new: items, current: currentID, destination: destination) {
                    needsReconcile = true
                }
            }
            itemIDs = items; currentID = current
            anchor = current.flatMap { items.firstIndex(of: $0) } ?? 0
        }
        var targetIndex: Int?
        var requestID: UUID?
        private var handledRequest: UUID?
        func pageIfRequested() {
            guard !isSuspended else { return }
            if let scroll { observePageSize(scroll) }
            if restoringFullscreen, let scroll, scroll.window != nil, scroll.bounds.height > 0 {
                needsReconcile = false // the latest active-ID anchor also incorporates playlist edits
                // Fullscreen changes the window geometry while SwiftUI's scrollPosition is suspended.
                // Restore by active ID, and suppress commits until the returning geometry is quiet.
                let y = Double(anchor) * scroll.bounds.height - scroll.adjustedContentInset.top
                if abs(scroll.contentOffset.y - y) > 0.5 { scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: false) }
                scheduleFallback(after: 0.5)
                return
            }
            if needsReconcile, let scroll, scroll.bounds.height > 0 {
                needsReconcile = false; suppressCommit = true
                fallback?.cancel(); fallback = nil
                // Cancels a drag/deceleration and anchors by the settled item's new index.
                scroll.panGestureRecognizer.isEnabled = false
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: Double(anchor) * scroll.bounds.height - scroll.adjustedContentInset.top), animated: false)
                scroll.panGestureRecognizer.isEnabled = true
                suppressCommit = false
            }
            guard let index = targetIndex, let requestID, requestID != handledRequest,
                  let scroll, !scroll.isDragging, !scroll.isDecelerating, scroll.bounds.height > 0 else { return }
            handledRequest = requestID
            let y = Double(index) * scroll.bounds.height - scroll.adjustedContentInset.top
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: true)
        }
        weak var scroll: UIScrollView?
        weak var original: UIScrollViewDelegate?
        init(commit: @escaping (String, TimeInterval) -> Void, reference: HMScrollViewReference?, interaction: @escaping (Bool) -> Void) {
            self.commit = commit; self.reference = reference; self.interaction = interaction
        }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            restoringFullscreen = false; reference?.isRestoringFullscreen = false
            pageSize = scrollView.bounds.size
            fallback?.cancel(); fallback = nil
            interaction(true)
            original?.scrollViewWillBeginDragging?(scrollView)
        }
        override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || (original?.responds(to: selector) ?? false) }
        override func forwardingTarget(for selector: Selector!) -> Any? { original }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            let time = ProcessInfo.processInfo.systemUptime
            original?.scrollViewDidEndDecelerating?(scrollView); settled(scrollView, time: time)
        }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            let time = ProcessInfo.processInfo.systemUptime
            original?.scrollViewDidEndDragging?(scrollView, willDecelerate: decelerate)
            if !decelerate { settled(scrollView, time: time) }
        }
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            let time = ProcessInfo.processInfo.systemUptime
            original?.scrollViewDidEndScrollingAnimation?(scrollView); settled(scrollView, time: time)
        }
        private func settled(_ scroll: UIScrollView, time: TimeInterval) {
            fallback?.cancel(); fallback = nil
            observePageSize(scroll)
            guard !isSuspended, !suppressCommit, !needsReconcile, !scroll.isDragging, !scroll.isDecelerating, scroll.bounds.height > 0 else { return }
            if restoringFullscreen {
                let y = Double(anchor) * scroll.bounds.height - scroll.adjustedContentInset.top
                if abs(scroll.contentOffset.y - y) > 0.5 {
                    scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: false)
                    lastMotionAt = ProcessInfo.processInfo.systemUptime
                }
                let quiet = ProcessInfo.processInfo.systemUptime - lastMotionAt
                if quiet < 0.5 { scheduleFallback(after: 0.5 - quiet); return }
                restoringFullscreen = false; reference?.isRestoringFullscreen = false; interaction(false)
                return
            }
            defer { interaction(false) }
            let index = max(0, Int(((scroll.contentOffset.y + scroll.adjustedContentInset.top) / scroll.bounds.height).rounded()))
            guard itemIDs.indices.contains(index) else { return }
            commit(itemIDs[index], time)
        }
    }
}
#endif
