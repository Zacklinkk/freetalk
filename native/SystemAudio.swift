import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// The sound the Mac plays (the remote side of a call), recorded with
/// ScreenCaptureKit as a 16 kHz mono track next to the microphone. Needs the
/// Screen Recording permission. No picture is kept: the stream's 2×2 frames
/// are dropped as they arrive. freetalk's own sound is excluded.
///
/// ScreenCaptureKit delivers audio only while something plays to the output
/// device (also when it is muted), so the track starts at the first sound and
/// silences between sounds are filled in.
final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "io.github.zacklinkk.freetalk.system-audio")
    private let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
    // Touched only on `queue`.
    private var writer: MeetingWAVWriter?
    private var converter: AVAudioConverter?, inputFormat: AVAudioFormat?
    private var pending = Data()
    private var first: Double?, next: Double?
    private var failure: String?
    /// Called on the main thread when capture stops by itself (permission revoked, display gone).
    var onError: ((String) -> Void)?

    /// Host-clock seconds of the track's first sample, to line it up with the microphone.
    var firstSampleTime: Double? { queue.sync { first } }

    func start(writingTo url: URL, completion: @escaping (Error?) -> Void) {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else { throw VoiceError.message("没有可以录制声音的显示器") }
                let configuration = SCStreamConfiguration()
                configuration.capturesAudio = true; configuration.excludesCurrentProcessAudio = true
                configuration.sampleRate = 16000; configuration.channelCount = 1
                configuration.width = 2; configuration.height = 2
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1); configuration.showsCursor = false
                let writer = try MeetingWAVWriter(url: url)
                queue.sync { self.writer = writer; self.pending = Data(); self.first = nil; self.next = nil; self.failure = nil; self.converter = nil }
                let stream = SCStream(filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []), configuration: configuration, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                try await stream.startCapture()
                await MainActor.run { self.stream = stream; completion(nil) }
            } catch {
                queue.sync { self.writer?.close(); self.writer = nil }
                await MainActor.run { completion(error) }
            }
        }
    }

    /// Stop, write what is buffered and close the file; `completion` runs on the main thread.
    func stop(_ completion: @escaping () -> Void) {
        let finish = { [weak self] in
            guard let self = self else { DispatchQueue.main.async(execute: completion); return }
            self.queue.async {
                self.flush(force: true); self.writer?.close(); self.writer = nil
                DispatchQueue.main.async(execute: completion)
            }
        }
        guard let stream = stream else { finish(); return }
        self.stream = nil
        stream.stopCapture { _ in finish() }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.flush(force: true) }
        DispatchQueue.main.async { self.onError?(error.localizedDescription) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, writer != nil, failure == nil, sampleBuffer.isValid,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              var stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              let format = AVAudioFormat(streamDescription: &stream) else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        input.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList) == noErr else { return }
        if converter == nil || inputFormat != format {
            converter = AVAudioConverter(from: format, to: output); converter?.primeMethod = .none; inputFormat = format
        }
        guard let converter = converter,
              let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(ceil(Double(frames) * 16000 / format.sampleRate)) + 64) else { return }
        var supplied = false, error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, flag in
            if supplied { flag.pointee = .noDataNow; return nil }
            supplied = true; flag.pointee = .haveData; return input
        }
        guard status != .error, let samples = converted.int16ChannelData?[0] else { return }
        // Nothing playing can mean no buffers at all; fill the gap with silence
        // so the track's time keeps matching the microphone's.
        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        if first == nil { first = time }
        if let expected = next, time - expected > 0.05 { pending.append(Data(count: Int((time - expected) * 16000) * 2)) }
        next = time + Double(frames) / format.sampleRate
        pending.append(UnsafeBufferPointer(start: samples, count: Int(converted.frameLength)))
        flush(force: false)
    }

    /// One write a second, like the microphone track; each write updates the header and syncs.
    private func flush(force: Bool) {
        guard let writer = writer, pending.count >= (force ? 1 : 32000) else { return }
        do { try writer.append(pending); pending.removeAll(keepingCapacity: true) }
        catch {
            failure = error.localizedDescription; pending.removeAll()
            DispatchQueue.main.async { self.onError?(error.localizedDescription) }
        }
    }
}
