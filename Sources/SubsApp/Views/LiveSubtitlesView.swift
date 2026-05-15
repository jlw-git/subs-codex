import SwiftUI
import Translation

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
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(store.currentTranslatedSubtitle.isEmpty ? "Translation will appear here." : store.currentTranslatedSubtitle)
                    .font(.system(size: 26, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
            }
            .padding(22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

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

            if #unavailable(macOS 15.0) {
                Text("On-device translation requires macOS 15 or later. Local speech-to-text still runs on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }

            Spacer()
        }
        .padding(20)
        .navigationTitle("Live")
        .background {
            if #available(macOS 15.0, *) {
                TranslationTaskHost()
                    .environmentObject(store)
                    .frame(width: 0, height: 0)
            }
        }
    }
}

@available(macOS 15.0, *)
private struct TranslationTaskHost: View {
    @EnvironmentObject private var store: MeetingSessionStore
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .onChange(of: store.pendingTranslation?.id) { _, _ in
                guard let job = store.pendingTranslation else {
                    configuration = nil
                    return
                }

                configuration = TranslationSession.Configuration(
                    source: job.sourceLanguage,
                    target: job.targetLanguage
                )
                configuration?.invalidate()
            }
            .translationTask(configuration) { session in
                guard let job = store.pendingTranslation else { return }

                do {
                    let response = try await session.translate(job.sourceText)
                    store.applyTranslation(response.targetText, for: job)
                } catch {
                    store.translationFailed(error, for: job)
                }
            }
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
