import SwiftUI

struct TranscriptMemoryView: View {
    @EnvironmentObject private var store: MeetingSessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Bilingual Transcript Memory", systemImage: "rectangle.stack")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            if store.segments.isEmpty {
                ContentUnavailableView("No transcript yet", systemImage: "captions.bubble", description: Text("Start capture to create local bilingual memory."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(store.segments.reversed()) { segment in
                            TranscriptRow(segment: segment)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .background(.background)
    }
}

private struct TranscriptRow: View {
    let segment: TranscriptSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(segment.speaker)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(segment.timestamp, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(segment.sourceText)
                .font(.callout)

            Text(segment.translatedText)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
