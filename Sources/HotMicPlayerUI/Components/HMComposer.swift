#if os(iOS)
import SwiftUI
import HotMicPlayer

/// A one-line chat composer. The message lands at the item's current media time.
///
/// Focuses itself on appear. While a message is sending the field is disabled; on
/// failure the text is kept and an inline error explains why, so the viewer can
/// retry. Renders nothing when the source can't send chat.
public struct HMComposer: View {

    private let engagement: HMEngagement
    private let placeholder: String
    private let autofocus: Bool
    private let onSent: (() -> Void)?
    private let onDismiss: (() -> Void)?

    @Environment(\.hmTheme) private var theme
    @ScaledMetric(relativeTo: .title2) private var sendSize: CGFloat = 30
    @FocusState private var focused: Bool
    @State private var text = ""
    @State private var isSending = false
    @State private var error: String?

    /// Creates a composer.
    /// - Parameters:
    ///   - onSent: Called after the source accepts a message.
    ///   - onDismiss: Shows a close button when provided; also called on submit of an empty field.
    public init(engagement: HMEngagement, placeholder: String = "Add a comment…", autofocus: Bool = true,
                onSent: (() -> Void)? = nil, onDismiss: (() -> Void)? = nil) {
        self.engagement = engagement
        self.placeholder = placeholder
        self.autofocus = autofocus
        self.onSent = onSent
        self.onDismiss = onDismiss
    }

    public var body: some View {
        if engagement.supports(.sendChat) {
            VStack(alignment: .leading, spacing: 6) {
                if let error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(theme.fonts.caption)
                        .foregroundStyle(.red)
                        .transition(.opacity)
                }
                HStack(spacing: 8) {
                    if let onDismiss {
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 36, height: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close composer")
                    }
                    // Single-line on purpose: Return sends, as in every chat surface.
                    TextField(placeholder, text: $text)
                        .font(theme.fonts.body)
                        .focused($focused)
                        .submitLabel(.send)
                        .onSubmit(send)
                        .disabled(isSending)
                        .frame(minHeight: 44)
                        .accessibilityLabel("Comment")
                        .onChange(of: text) { _, _ in error = nil }
                    if remaining < 30 {
                        Text("\(remaining)")
                            .font(theme.fonts.metric)
                            .foregroundStyle(remaining < 0 ? .red : .secondary)
                            .accessibilityLabel("\(remaining) characters left")
                    }
                    sendButton
                }
                .padding(.leading, onDismiss == nil ? 14 : 4)
                .padding(.trailing, 4)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous).fill(.primary.opacity(0.06)))
            }
            .padding(8)
            .hmCard(theme)
            .animation(.snappy(duration: 0.2), value: error)
            .onAppear { if autofocus { focused = true } }
        }
    }

    private var remaining: Int { HMEngagement.maximumMessageLength - text.count }
    private var canSend: Bool {
        !isSending && remaining >= 0 && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sendButton: some View {
        Button(action: send) {
            ZStack {
                if isSending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: theme.icons.send)
                        .font(.system(size: sendSize))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(canSend ? theme.colors.accent : Color.secondary.opacity(0.5))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .accessibilityLabel("Send")
    }

    private func send() {
        guard canSend else {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onDismiss?() }
            return
        }
        let message = text
        isSending = true
        Task {
            defer { isSending = false }
            do {
                try await engagement.sendChat(message)
                text = ""
                onSent?()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't send. Try again."
                focused = true
            }
        }
    }
}
#endif
