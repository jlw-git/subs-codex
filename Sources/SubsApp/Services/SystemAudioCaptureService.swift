import Foundation
import AVFoundation
import OSLog
import ScreenCaptureKit

private let audioCaptureLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.jlwong.Subs",
    category: "AudioCapture"
)

@MainActor
final class SystemAudioCaptureService: NSObject, ObservableObject {
    @Published private(set) var state: CaptureState = .idle
    @Published private(set) var audioPulse: Double = 0

    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onFirstAudioBuffer: (() -> Void)?

    private var stream: SCStream?
    private var receivedBufferCount = 0

    func start() async {
        guard stream == nil else { return }
        state = .requestingPermission
        receivedBufferCount = 0

        do {
            audioCaptureLogger.info("Requesting shareable content for system audio capture")
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                audioCaptureLogger.error("No display is available for system audio capture")
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
            audioCaptureLogger.info("System audio capture stream started")
        } catch {
            audioCaptureLogger.error("System audio capture failed to start: \(error.localizedDescription, privacy: .public)")
            state = .failed(Self.permissionMessage(for: error))
        }
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        audioPulse = 0
        receivedBufferCount = 0
        state = .idle
    }

    private func receiveAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        receivedBufferCount += 1
        let level = buffer.rmsLevel
        audioPulse = level
        if receivedBufferCount == 1 || receivedBufferCount.isMultiple(of: 100) {
            audioCaptureLogger.info(
                "Received system audio buffer \(self.receivedBufferCount, privacy: .public), frames: \(buffer.frameLength, privacy: .public), sample rate: \(buffer.format.sampleRate, privacy: .public), rms: \(level, privacy: .public)"
            )
        }
        if receivedBufferCount == 1 {
            onFirstAudioBuffer?()
        }
        onAudioBuffer?(buffer)
    }

    private static func permissionMessage(for error: Error) -> String {
        "Screen & System Audio Recording permission is required. Open System Settings > Privacy & Security > Screen & System Audio Recording, allow Subs, then restart capture. Error: \(error.localizedDescription)"
    }
}

extension SystemAudioCaptureService: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let pcmBuffer = sampleBuffer.toPCMBuffer() else {
            audioCaptureLogger.error("Could not convert ScreenCaptureKit audio sample buffer")
            return
        }
        Task { @MainActor in
            receiveAudioBuffer(pcmBuffer)
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
        var listSize = 0

        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: &listSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )

        guard sizeStatus == noErr, listSize > 0 else { return nil }

        let rawAudioBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: listSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawAudioBufferList.deallocate() }

        let audioBufferList = rawAudioBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: listSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else { return nil }

        let source = UnsafeMutableAudioBufferListPointer(audioBufferList)
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

private extension AVAudioPCMBuffer {
    var rmsLevel: Double {
        guard frameLength > 0, let channelData = floatChannelData else { return 0 }

        let channelCount = Int(format.channelCount)
        let frameCount = Int(frameLength)
        var sumSquares: Double = 0
        var sampleCount = 0

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameCount {
                let sample = Double(samples[frame])
                sumSquares += sample * sample
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else { return 0 }
        return sqrt(sumSquares / Double(sampleCount))
    }
}
