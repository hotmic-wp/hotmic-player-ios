#if os(iOS)
import SwiftUI
import HotMicPlayer

/// The poll on screen at the playhead: vote while it's open, then results.
///
/// Appears when a poll's media-time window opens and stays for a few seconds
/// after it closes so the final result can be read. Scrubbing back to a poll
/// shows it again, with the viewer's vote kept. Without the `.vote` capability
/// the card shows live results only. Renders nothing when no poll is visible.
///
/// Access on the main actor.
public struct HMPollCard: View {

    private let engagement: HMEngagement
    private let mediaTime: TimeInterval
    private let resultsLinger: TimeInterval

    @Environment(\.hmTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var votedCount = 0

    /// Creates a poll card at a media time.
    /// - Parameter resultsLinger: Seconds a closed poll's results stay on screen.
    ///
    /// - Parameter engagement: Engagement state to display and send viewer actions through.
    /// - Parameter mediaTime: Current item time in seconds, used to query the engagement timeline.
    ///
    /// Access on the main actor.
    public init(engagement: HMEngagement, mediaTime: TimeInterval, resultsLinger: TimeInterval = 6) {
        self.engagement = engagement
        self.mediaTime = mediaTime
        self.resultsLinger = resultsLinger
    }

    /// Renders the component from current state when SwiftUI evaluates the view.
    /// Access on the main actor.
    public var body: some View {
        let poll = engagement.polls(at: mediaTime, resultsLinger: resultsLinger).first
        ZStack {
            if let poll {
                card(poll)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.94, anchor: .bottomLeading).combined(with: .opacity))
                    .id(poll.id)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.15), value: poll?.id)
        .sensoryFeedback(.selection, trigger: votedCount)
    }

    private func card(_ poll: HMPoll) -> some View {
        let offset = engagement.timelineOffset(forMediaTime: mediaTime)
        let isOpen = poll.isOpen(at: offset)
        let showsResults = poll.viewerVote != nil || !isOpen || !engagement.supports(.vote)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: theme.icons.poll)
                    .foregroundStyle(theme.colors.accent)
                Text(isOpen ? "Poll" : "Final results")
                    .textCase(.uppercase)
                    .tracking(0.6)
                Spacer(minLength: 0)
                if isOpen, let closesAt = poll.closesAt {
                    Text(HMFormat.timecode(max(0, closesAt - offset)))
                        .font(theme.fonts.metric)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText(countsDown: true))
                        .accessibilityLabel("Closes in \(HMFormat.spoken(max(0, closesAt - offset)))")
                }
            }
            .font(theme.fonts.caption)
            .foregroundStyle(.secondary)

            Text(poll.question)
                .font(theme.fonts.headline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 5) {
                ForEach(poll.options) { option in
                    if showsResults {
                        result(option, in: poll, isFinal: !isOpen)
                    } else {
                        voteButton(option, in: poll)
                    }
                }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.35), value: showsResults)

            Text("\(poll.totalVotes.formatted()) votes")
                .font(theme.fonts.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(value: Double(poll.totalVotes)))
        }
        .padding(12)
        .frame(maxWidth: 264, alignment: .leading)
        .hmCard(theme)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Poll")
    }

    private func voteButton(_ option: HMPoll.Option, in poll: HMPoll) -> some View {
        Button {
            Task {
                do { try await engagement.vote(pollID: poll.id, optionID: option.id); votedCount += 1 } catch {}
            }
        } label: {
            Text(option.text)
                .font(theme.fonts.emphasis)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 36)
                .padding(.horizontal, 12)
                .background(Capsule().fill(.primary.opacity(0.06)))
                .overlay(Capsule().strokeBorder(theme.colors.accent.opacity(0.7), lineWidth: 1.2))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.text)
        .accessibilityHint("Votes in this poll")
    }

    private func result(_ option: HMPoll.Option, in poll: HMPoll, isFinal: Bool) -> some View {
        let share = poll.share(of: option.id)
        let isChoice = poll.viewerVote == option.id
        let isLeader = isFinal && option.votes == poll.options.map(\.votes).max() && option.votes > 0
        let percent = Int((share * 100).rounded())

        return HStack(spacing: 8) {
            if isChoice {
                Image(systemName: theme.icons.selected).foregroundStyle(theme.colors.accent)
            }
            Text(option.text)
                .font(isChoice || isLeader ? theme.fonts.emphasis : theme.fonts.body)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text("\(percent)%")
                .font(theme.fonts.metric)
                .foregroundStyle(.primary)
                .contentTransition(.numericText(value: Double(percent)))
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(alignment: .leading) {
            GeometryReader { proxy in
                Capsule()
                    .fill(isChoice
                          ? AnyShapeStyle(LinearGradient(colors: [theme.colors.accent.opacity(0.55), theme.colors.accentSecondary.opacity(0.45)],
                                                         startPoint: .leading, endPoint: .trailing))
                          : AnyShapeStyle(.primary.opacity(isLeader ? 0.16 : 0.09)))
                    .frame(width: max(proxy.size.height, proxy.size.width * share))
            }
        }
        .background(Capsule().fill(.primary.opacity(0.04)))
        .clipShape(.capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(option.text), \(percent) percent\(isChoice ? ", your vote" : "")\(isLeader ? ", winner" : "")")
    }
}
#endif
