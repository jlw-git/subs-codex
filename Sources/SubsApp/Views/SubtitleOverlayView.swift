import SwiftUI

struct SubtitleOverlayView: View {
    @EnvironmentObject private var store: MeetingSessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(store.isRunning ? "Live" : store.statusTitle, systemImage: store.isRunning ? "waveform" : store.primaryActionSystemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(store.isRunning ? .green : .secondary)

                Spacer()

                CaptureMeterCompact(level: store.capture.audioPulse)
            }

            Text(store.currentSourceSubtitle)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .lineLimit(2)
                .minimumScaleFactor(0.7)

            Text(store.currentTranslatedSubtitle.isEmpty ? "Translation will appear here." : store.currentTranslatedSubtitle)
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
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
