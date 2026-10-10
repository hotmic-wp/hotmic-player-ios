#if os(iOS)
import SwiftUI
import UIKit
import HotMicPlayer

/// Default list + composer, also usable as replacement content in a host sheet.
/// Keeps failed drafts, prevents duplicate submissions and offers explicit pagination.
public struct HMCommentSheet: View {
    /// Host-owned observable data source for this item.
    public let data: any HMSocialDataSource
    /// Called after a successful submission; failed drafts remain in the composer.
    public var onPosted: (String) -> Void
    @Environment(\.hmTheme) private var theme
    @State private var draft = ""
    @State private var busy = false
    @State private var loading = false
    @State private var error: String?
    /// Creates this component with host-supplied data and actions.
    public init(data: any HMSocialDataSource, onPosted: @escaping (String) -> Void = { _ in }) {
        self.data = data; self.onPosted = onPosted
    }
    /// Renders the component using current observable data and environment theme.
    public var body: some View {
        VStack(spacing: 8) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if data.canLoadMore {
                        Button(loading ? "Loading comments" : "Load more comments") { Task { await load() } }
                            .disabled(loading).frame(minHeight: 44).accessibilityIdentifier("hm-load-comments")
                    }
                    ForEach(data.content.comments) { comment in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(comment.author).font(theme.fonts.emphasis)
                            Text(comment.text).font(theme.fonts.body)
                        }.accessibilityElement(children: .combine)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
            }.accessibilityIdentifier("hm-comment-list")
            if let error { Text(error).font(theme.fonts.caption).foregroundStyle(.red).accessibilityIdentifier("hm-comment-error") }
            if data.canPost {
                HStack {
                    TextField("Add a comment", text: $draft, axis: .vertical).lineLimit(1...3)
                        .textFieldStyle(.roundedBorder).accessibilityIdentifier("hm-comment-input")
                    Button(busy ? "Posting" : "Post") {
                        let submitted = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        busy = true; error = nil
                        Task {
                            defer { busy = false }
                            do {
                                try await data.postComment(submitted)
                                if draft.trimmingCharacters(in: .whitespacesAndNewlines) == submitted { draft = "" }
                                onPosted(submitted)
                            } catch is CancellationError { }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("hm-post-comment")
                }.padding(.horizontal)
            }
        }.task { if data.canLoadMore { await load() } }
    }
    private func load() async {
        guard !loading else { return }; loading = true; error = nil
        defer { loading = false }
        do { try await data.loadMoreComments() }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}

/// SwiftUI native share helper. Present using `.sheet`; UIKit hosts can use `present(items:from:sourceView:)`.
public struct HMShareSheet: UIViewControllerRepresentable {
    /// Activity items supplied to the native share controller.
    public var items: [Any]
    /// Creates this component with host-supplied data and actions.
    public init(items: [Any]) { self.items = items }
    /// Creates the native activity controller for these items.
    public func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    /// Keeps the presented native activity controller stable during SwiftUI updates.
    public func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
    /// Anchors iPad popovers to the supplied source view (or the presenter view).
    @MainActor public static func present(items: [Any], from presenter: UIViewController, sourceView: UIView? = nil) {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let source = sourceView ?? presenter.view!
        controller.popoverPresentationController?.sourceView = source
        controller.popoverPresentationController?.sourceRect = source.bounds
        presenter.present(controller, animated: true)
    }
}
#endif
