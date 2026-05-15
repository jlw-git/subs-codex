import Foundation
import AVFoundation
import ScreenCaptureKit

@MainActor
final class SystemAudioCaptureService: NSObject, ObservableObject {
    @Published private(set) var state: CaptureState = .idle
    @Published private(set) var audioPulse: Double = 0

    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    private var stream: SCStream?

    func start() async {
        guard stream == nil else { return }
        state = .requestingPermission

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                state = .failed("No display is available for local system-audio capture.")
                return
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
            try await stream.startCapture()
            self.stream = stream
            state = .running
        } catch {
            state = .failed(Self.permissionMessage(for: error))
        }
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        audioPulse = 0
        state = .idle
    }

    private static func permissionMessage(for error: Error) -> String {
        "Screen & System Audio Recording permission is required. Open System Settings > Privacy & Security > Screen & System Audio Recording, allow Subs, then restart capture. Error: \(error.localizedDescription)"
    }
}

extension SystemAudioCaptureService: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let pcmBuffer = sampleBuffer.toPCMBuffer() else { return }
        Task { @MainActor in
            audioPulse = Double.random(in: 0.35...1.0)
            onAudioBuffer?(pcmBuffer)
        }
    }
}

private extension CMSampleBuffer {
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(self),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        guard let audioFormat = AVAudioFormat(streamDescription: streamDescription) else {
            return nil
        }
        let sampleCount = CMSampleBufferGetNumSamples(self)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            frameCapacity: AVAudioFrameCount(sampleCount)
        ) else {
            return nil
        }

        buffer.frameLength = buffer.frameCapacity
        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else { return nil }

        let source = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            guard let sourceData = source[index].mData,
                  let destinationData = destination[index].mData else {
                continue
            }

            memcpy(destinationData, sourceData, Int(source[index].mDataByteSize))
            destination[index].mDataByteSize = source[index].mDataByteSize
        }

        return buffer
    }
}
