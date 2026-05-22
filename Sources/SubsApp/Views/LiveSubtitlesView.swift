import SwiftUI

struct LiveSubtitlesView: View {
    @EnvironmentObject private var store: MeetingSessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PrivacyBanner()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Realtime Subtitles", systemImage: "captions.bubble")
                        .font(.headline)
                    Spacer()
                    CaptureMeter(level: store.capture.audioPulse)
                }

                Text(store.currentSourceSubtitle)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .italic(store.isCurrentSourceSubtitleCandidate)
                    .foregroundStyle(store.isCurrentSourceSubtitleCandidate ? .secondary : .primary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if store.isCurrentSourceSubtitleCandidate {
                    Label("Candidate", systemImage: "waveform.badge.magnifyingglass")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Text(store.currentTranslatedSubtitle.isEmpty ? "Translation will appear here." : store.currentTranslatedSubtitle)
                    .font(.system(size: 26, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
            }
            .padding(22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

            RecognitionDebugPanel(metrics: store.speech.debugMetrics)

            if case .failed(let message) = store.capture.state {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }

            if case .failed(let message) = store.speech.state {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }

            Spacer()
        }
        .padding(20)
        .navigationTitle("Live")
    }
}

private struct RecognitionDebugPanel: View {
    let metrics: RecognitionDebugMetrics

    private let columns = [
        GridItem(.adaptive(minimum: 132), spacing: 10, alignment: .leading)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Recognition Debug", systemImage: "waveform.path.ecg")
                .font(.headline)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                DebugMetric(title: "RMS", value: String(format: "%.4f", metrics.latestRMS))
                DebugMetric(title: "Skipped", value: metrics.skippedQuietChunks.formatted())
                DebugMetric(title: "Low confidence", value: metrics.filteredLowConfidenceChunks.formatted())
                DebugMetric(title: "Duplicates", value: metrics.filteredDuplicateChunks.formatted())
                DebugMetric(title: "Candidates", value: metrics.candidateChunks.formatted())
                DebugMetric(title: "Accepted", value: metrics.acceptedChunks.formatted())
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DebugMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PrivacyBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text("Local-only session")
                    .font(.headline)
                Text("Audio capture, subtitles, translation, and transcript memory stay on this Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(14)
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
        .accessibilityLabel("Local audio activity")
    }

    private func indexLevel(_ index: Int) -> Double {
        Double(index + 1) / 7.0
    }
}
