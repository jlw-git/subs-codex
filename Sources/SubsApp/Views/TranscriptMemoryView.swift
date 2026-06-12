import SwiftUI

struct TranscriptMemoryView: View {
    @EnvironmentObject private var store: MeetingSessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Transcript", systemImage: "rectangle.stack")
                    .font(.headline)

                Spacer()

                Text("\(store.segments.count) lines")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Button {
                    store.clearTranscript()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .help("Clear transcript")
                .disabled(store.segments.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            if store.segments.isEmpty {
                ContentUnavailableView(
                    "No transcript",
                    systemImage: "captions.bubble",
                    description: Text("Accepted subtitles appear here.")
                )
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
                    .foregroundStyle(.secondary)
                Spacer()
                Text(segment.timestamp, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(segment.translatedText)
                .font(.callout)
                .fontWeight(.medium)

            Text(segment.sourceText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
