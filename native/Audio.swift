import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

struct MicDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let builtIn: Bool
    let transport: String
}

enum MicDevices {
    static func all() -> [MicDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
            func string(_ selector: AudioObjectPropertySelector) -> String {
                var attr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var value: Unmanaged<CFString>?
                var length = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                guard AudioObjectGetPropertyData(id, &attr, 0, nil, &length, &value) == noErr else { return "" }
                return value?.takeUnretainedValue() as String? ?? ""
            }
            var transport: UInt32 = 0
            var length = UInt32(MemoryLayout<UInt32>.size)
            var attr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            _ = AudioObjectGetPropertyData(id, &attr, 0, nil, &length, &transport)
            let kind = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE ? "蓝牙" : transport == kAudioDeviceTransportTypeBuiltIn ? "内置" : transport == kAudioDeviceTransportTypeUSB ? "USB" : "其他"
            return MicDevice(id: id, uid: string(kAudioDevicePropertyDeviceUID), name: string(kAudioObjectPropertyName), builtIn: transport == kAudioDeviceTransportTypeBuiltIn, transport: kind)
        }
    }
    static func defaultInputID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }
    static func selected(uid: String?, devices: [MicDevice]) -> MicDevice? {
        if let uid = uid { return devices.first { $0.uid == uid } }
        let id = defaultInputID(); return devices.first { $0.id == id }
    }
}

final class MicDeviceMonitor {
    var onChange: (() -> Void)?
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    func start() {
        guard listeners.isEmpty else { return }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange?() }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr { listeners.append((address, block)) }
        }
    }
    deinit { for (var address, block) in listeners { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) } }
}

enum VoiceError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

final class Recorder {
    private var engine: AVAudioEngine?
    private var engineUID: String?
    private var tapInstalled = false
    private let control = DispatchQueue(label: "local.voice.audio.control", qos: .userInitiated)
    private let queue = DispatchQueue(label: "local.voice.audio")
    private let lock = NSLock()
    private var generation = UUID()
    private var preparationGeneration = UUID()
    private var captureRequested = false
    private(set) var isRunning = false
    private var pending = Data()
    private var samples = 0
    private var peak: Float = 0
    private var failed = false
    var onChunk: ((Data) -> Void)?
    var onLevel: ((Float, Double) -> Void)?
    var onError: ((String) -> Void)?
    var onTiming: (([String: Any]) -> Void)?
    private func valid(_ token: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return generation == token }
    private func nextGeneration(recording: Bool) -> UUID { lock.lock(); defer { lock.unlock() }; generation = UUID(); captureRequested = recording; return generation }

    /// Resolve the expensive input node and format without installing a tap or starting hardware.
    func prepareDevice(_ device: MicDevice, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        lock.lock(); preparationGeneration = UUID(); let token = preparationGeneration; lock.unlock()
        control.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock(); let allowed = !self.captureRequested && self.preparationGeneration == token; self.lock.unlock()
            guard allowed else { return }
            let began = ProcessInfo.processInfo.systemUptime
            do {
                var report: [String: Any] = [:]
                let (audio, _, _, _, _) = try self.configure(device: device, timings: &report)
                report["preparation_ms"] = (ProcessInfo.processInfo.systemUptime-began)*1000
                report["audio_running"] = audio.isRunning; report["tap_installed"] = self.tapInstalled
                DispatchQueue.main.async { completion(.success(report)) }
            } catch {
                self.engine = nil; self.engineUID = nil
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func start(device: MicDevice, completion: @escaping (Result<Void, Error>) -> Void) {
        let token = nextGeneration(recording: true), began = ProcessInfo.processInfo.systemUptime
        control.async { [weak self] in
            guard let self = self, self.valid(token) else { return }
            do { try self.open(device: device, token: token, began: began, completion: completion) }
            catch {
                if let audio = self.engine { audio.stop(); if self.tapInstalled { audio.inputNode.removeTap(onBus: 0); self.tapInstalled = false } }
                self.engine = nil; self.engineUID = nil
                self.lock.lock(); if self.generation == token { self.captureRequested = false }; self.lock.unlock()
                DispatchQueue.main.async { if self.valid(token) { self.isRunning = false; completion(.failure(error)) } }
            }
        }
    }
    private func configure(device: MicDevice, timings: inout [String: Any]) throws -> (AVAudioEngine, AVAudioInputNode, AVAudioFormat, AVAudioFormat, AVAudioConverter) {
        timings = ["device": device.name, "transport": device.transport, "reused_engine": engine != nil && engineUID == device.uid]
        var step = ProcessInfo.processInfo.systemUptime
        if engineUID != device.uid { engine?.stop(); engine = nil }
        let audio = engine ?? AVAudioEngine(); engine = audio; engineUID = device.uid
        timings["engine_ms"] = (ProcessInfo.processInfo.systemUptime-step)*1000; step = ProcessInfo.processInfo.systemUptime
        let input = audio.inputNode
        timings["input_node_ms"] = (ProcessInfo.processInfo.systemUptime-step)*1000; step = ProcessInfo.processInfo.systemUptime
        guard let unit = input.audioUnit else { throw VoiceError.message("无法打开麦克风") }
        var current: AudioDeviceID = 0, length = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &current, &length)
        var id = device.id
        if current != id { guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
            0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
            throw VoiceError.message("麦克风不可用，请重新选择：\(device.name)")
        } }
        timings["device_bind_ms"] = (ProcessInfo.processInfo.systemUptime-step)*1000; step = ProcessInfo.processInfo.systemUptime
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: output) else {
            throw VoiceError.message("麦克风没有有效音频格式")
        }
        converter.primeMethod = .none
        timings["sample_rate"] = format.sampleRate
        timings["format_ms"] = (ProcessInfo.processInfo.systemUptime-step)*1000
        return (audio, input, format, output, converter)
    }
    private func open(device: MicDevice, token: UUID, began: TimeInterval, completion: @escaping (Result<Void, Error>) -> Void) throws {
        var timings: [String: Any] = [:]
        let (audio, input, format, output, converter) = try configure(device: device, timings: &timings)
        guard valid(token) else { audio.stop(); return }
        queue.sync { pending.removeAll(); samples = 0; peak = 0; failed = false }
        var firstBuffer = true
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            // Own the tap buffer before crossing queues; AVAudioEngine reuses its storage.
            guard let self = self, self.valid(token), let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for index in source.indices {
                if let src = source[index].mData, let dst = target[index].mData {
                    memcpy(dst, src, Int(source[index].mDataByteSize))
                }
            }
            self.queue.async {
                guard !self.failed else { return }
                let capacity = AVAudioFrameCount(ceil(Double(copy.frameLength) * 16000 / format.sampleRate)) + 64
                guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
                var supplied = false
                var error: NSError?
                let status = converter.convert(to: converted, error: &error) { _, flag in
                    if supplied { flag.pointee = .noDataNow; return nil }
                    supplied = true; flag.pointee = .haveData; return copy
                }
                if status == .error {
                    self.failed = true
                    DispatchQueue.main.async { if self.valid(token) { self.onError?(error?.localizedDescription ?? "音频转换失败") } }
                    return
                }
                guard let pcm = converted.int16ChannelData?[0] else { return }
                let count = Int(converted.frameLength)
                guard count > 0 else { return }
                if firstBuffer {
                    firstBuffer = false
                    let elapsed = (ProcessInfo.processInfo.systemUptime-began)*1000
                    // Read timings only after start() has returned on the control queue.
                    self.control.async {
                        var report = timings; report["first_buffer_ms"] = elapsed
                        DispatchQueue.main.async { if self.valid(token) { self.isRunning = true; self.onTiming?(report); completion(.success(())) } }
                    }
                }
                var power: Float = 0
                for i in 0..<count { let f = Float(pcm[i]) / 32768; power += f * f }
                let rms = sqrt(power / Float(max(1,count)))
                self.peak = max(self.peak, rms)
                self.samples += count
                self.pending.append(UnsafeBufferPointer(start: pcm, count: count))
                let seconds = Double(self.samples) / 16000
                DispatchQueue.main.async { if self.valid(token) { self.onLevel?(rms, seconds) } }
                // Small pieces permit ASR at pauses while the microphone continues.
                if self.pending.count >= 32000 && self.valid(token) {
                    let chunk = self.pending; self.pending.removeAll(keepingCapacity: true)
                    DispatchQueue.main.async { if self.valid(token) { self.onChunk?(chunk) } }
                }
            }
        }
        tapInstalled = true
        let step = ProcessInfo.processInfo.systemUptime
        do { audio.prepare(); try audio.start(); timings["start_ms"] = (ProcessInfo.processInfo.systemUptime-step)*1000 }
        catch { input.removeTap(onBus: 0); tapInstalled = false; throw error }
        if !valid(token) { audio.stop(); input.removeTap(onBus: 0); tapInstalled = false }
    }

    func stop(_ completion: @escaping (Double, Float) -> Void) {
        let chunkHandler = onChunk
        _ = nextGeneration(recording: false); isRunning = false
        control.async {
          if let audio = self.engine { audio.stop(); if self.tapInstalled { audio.inputNode.removeTap(onBus: 0); self.tapInstalled = false } }
          self.queue.async {
            let tail = self.pending; self.pending.removeAll()
            let seconds = Double(self.samples) / 16000, peak = self.peak
            DispatchQueue.main.async {
                if !tail.isEmpty { chunkHandler?(tail) }
                completion(seconds, peak)
            }
          }
        }
    }
    func checkRunning(_ completion: @escaping (Bool) -> Void) {
        control.async { let active = self.engine?.isRunning ?? false; DispatchQueue.main.async { completion(active) } }
    }
}
