#if canImport(UIKit) && !os(watchOS)
import SwiftUI
import UIKit

/// iOS 17 bridge: scrollPosition changes during a drag; delegate end callbacks
/// identify the settled page. Forward other delegate messages to SwiftUI.
struct HMPageCommitProbe: UIViewRepresentable {
    var commit: (Int, TimeInterval) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(commit: commit) }
    func makeUIView(context: Context) -> Probe {
        let view = Probe(); view.coordinator = context.coordinator
        return view
    }
    func updateUIView(_ view: Probe, context: Context) { context.coordinator.commit = commit; view.connect() }
    static func dismantleUIView(_ view: Probe, coordinator: Coordinator) {
        if let scroll = coordinator.scroll, scroll.delegate === coordinator { scroll.delegate = coordinator.original }
    }
    final class Probe: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() { super.didMoveToWindow(); connect() }
        func connect() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let coordinator else { return }
                var ancestor = superview
                while let view = ancestor {
                    if let scroll = view as? UIScrollView {
                        if scroll.delegate !== coordinator {
                            coordinator.original = scroll.delegate
                            coordinator.scroll = scroll; scroll.delegate = coordinator
                        }
                        return
                    }
                    ancestor = view.superview
                }
            }
        }
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var commit: (Int, TimeInterval) -> Void
        weak var scroll: UIScrollView?
        weak var original: UIScrollViewDelegate?
        init(commit: @escaping (Int, TimeInterval) -> Void) { self.commit = commit }
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
            guard scroll.bounds.height > 0 else { return }
            commit(max(0, Int(((scroll.contentOffset.y + scroll.adjustedContentInset.top) / scroll.bounds.height).rounded())), time)
        }
    }
}
#endif
