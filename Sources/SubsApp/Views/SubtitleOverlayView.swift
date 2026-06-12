import SwiftUI

struct SubtitleOverlayView: View {
    @EnvironmentObject private var store: MeetingSessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(store.isRunning ? "Live subtitles" : store.statusTitle, systemImage: store.isRunning ? "waveform" : store.primaryActionSystemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(store.isRunning ? .green : .secondary)

                Spacer()

                CaptureMeterCompact(level: store.capture.audioPulse)
            }

            Text(primarySubtitle)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(textColor)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var primarySubtitle: String {
        store.overlayText
    }

    private var textColor: Color {
        if store.blockingErrorSummary != nil {
            return .red
        }

        return store.currentTranslatedSubtitle.isEmpty ? .secondary : .primary
    }
}

private struct CaptureMeterCompact: View {
    let level: Double

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(indexLevel(index) <= level ? Color.green : Color.secondary.opacity(0.25))
                    .frame(width: 4, height: CGFloat(8 + index * 4))
            }
        }
        .frame(width: 38, height: 28)
    }

    private func indexLevel(_ index: Int) -> Double {
        Double(index + 1) / 5.0
    }
}
