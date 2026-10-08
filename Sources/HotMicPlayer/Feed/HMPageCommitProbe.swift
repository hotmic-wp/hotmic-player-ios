#if canImport(UIKit) && !os(watchOS)
import SwiftUI
import UIKit

/// iOS 17 bridge: scrollPosition changes during a drag; delegate end callbacks
/// identify the settled page. Forward other delegate messages to SwiftUI.
@MainActor final class HMScrollViewReference {
    weak var scroll: UIScrollView?
    var lastMotionAt: TimeInterval = 0
}

struct HMPageCommitProbe: UIViewRepresentable {
    var targetIndex: Int?
    var requestID: UUID
    var reference: HMScrollViewReference? = nil
    var commit: (Int, TimeInterval) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(commit: commit, reference: reference) }
    func makeUIView(context: Context) -> Probe {
        let view = Probe(); view.coordinator = context.coordinator
        return view
    }
    func updateUIView(_ view: Probe, context: Context) {
        let coordinator = context.coordinator
        coordinator.commit = commit
        coordinator.reference = reference
        coordinator.targetIndex = targetIndex; coordinator.requestID = requestID
        view.connect()
    }
    static func dismantleUIView(_ view: Probe, coordinator: Coordinator) {
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
        var commit: (Int, TimeInterval) -> Void
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
            // Use the final movement's event clock, including fallback delay in
            // TTFF. A normal native settle commits earlier and cancels this.
            settled(scroll, time: lastMotionAt)
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            motionChanged()
            original?.scrollViewDidScroll?(scrollView)
        }
        var targetIndex: Int?
        var requestID: UUID?
        private var handledRequest: UUID?
        func pageIfRequested() {
            guard let index = targetIndex, let requestID, requestID != handledRequest,
                  let scroll, scroll.bounds.height > 0 else { return }
            handledRequest = requestID
            let y = Double(index) * scroll.bounds.height - scroll.adjustedContentInset.top
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: true)
        }
        weak var scroll: UIScrollView?
        weak var original: UIScrollViewDelegate?
        init(commit: @escaping (Int, TimeInterval) -> Void, reference: HMScrollViewReference?) { self.commit = commit; self.reference = reference }
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
            guard scroll.bounds.height > 0 else { return }
            commit(max(0, Int(((scroll.contentOffset.y + scroll.adjustedContentInset.top) / scroll.bounds.height).rounded())), time)
        }
    }
}
#endif
