import SwiftUI

struct LiveSubtitlesView: View {
    @EnvironmentObject private var store: MeetingSessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SessionBar()

            PipelineStatusStrip()

            SubtitleFocus()

            FailureMessages()

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .navigationTitle("Live")
    }
}

private struct SessionBar: View {
    @EnvironmentObject private var store: MeetingSessionStore

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .frame(width: 18)

            Text(store.statusTitle)
                .font(.headline)

            Text("\(store.sourceLanguage) to \(store.targetLanguage)")
                .foregroundStyle(.secondary)

            Text("Local only")
                .foregroundStyle(.green)

            Spacer()

            CaptureMeter(level: store.capture.audioPulse)
        }
        .font(.callout)
    }

    private var statusIcon: String {
        if store.isRunning { return "waveform" }
        if store.isStarting { return "hourglass" }
        if store.capture.state.failureMessage != nil || store.speech.state.failureMessage != nil {
            return "exclamationmark.triangle"
        }
        return "lock.shield"
    }

    private var statusColor: Color {
        if store.isRunning { return .green }
        if store.isStarting { return .blue }
        if store.capture.state.failureMessage != nil || store.speech.state.failureMessage != nil {
            return .red
        }
        return .secondary
    }
}

private struct PipelineStatusStrip: View {
    @EnvironmentObject private var store: MeetingSessionStore

    var body: some View {
        HStack(spacing: 10) {
            ForEach(store.livePipelineStatusItems) { item in
                PipelineStatusPill(item: item)
            }

            Spacer(minLength: 0)
        }
    }
}

private struct PipelineStatusPill: View {
    let item: LivePipelineStatusItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.systemImage)
                .foregroundStyle(tint)
                .frame(width: 16)

            Text(item.title)
                .font(.caption.weight(.semibold))

            Text(item.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var tint: Color {
        switch item.tone {
        case .ready: .green
        case .checking: .blue
        case .critical: .red
        case .neutral: .secondary
        }
    }
}

private struct SubtitleFocus: View {
    @EnvironmentObject private var store: MeetingSessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(primaryText)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(store.isLivePrimaryPlaceholder ? .secondary : .primary)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let secondarySourceText = store.liveSecondarySourceText {
                Text(store.sourceLanguage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(secondarySourceText)
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                    .italic(store.isCurrentSourceSubtitleCandidate)
                    .foregroundStyle(store.isCurrentSourceSubtitleCandidate ? .secondary : .primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
    }

    private var primaryText: String {
        store.livePrimaryText
    }
}

private struct FailureMessages: View {
    @EnvironmentObject private var store: MeetingSessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let blockingErrorSummary = store.blockingErrorSummary {
                FailureBanner(
                    title: blockingErrorSummary.title,
                    message: blockingErrorSummary.message
                )
            }
        }
    }
}

private struct FailureBanner: View {
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CaptureMeter: View {
    let level: Double

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<7, id: \.self) { index in
                Capsule()
                    .fill(indexLevel(index) <= level ? Color.green : Color.secondary.opacity(0.25))
                    .frame(width: 4, height: CGFloat(10 + index * 4))
            }
        }
        .frame(width: 56, height: 38)
        .accessibilityLabel("System audio activity")
    }

    private func indexLevel(_ index: Int) -> Double {
        Double(index + 1) / 7.0
    }
}
