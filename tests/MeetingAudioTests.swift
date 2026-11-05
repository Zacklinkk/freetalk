import Foundation
import AVFoundation

@main struct MeetingAudioTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("freetalk-meeting-audio-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("audio.wav")
        let writer = try MeetingWAVWriter(url:url)
        try writer.append(Data(count:16000*2*10))
        let partial = try AVAudioFile(forReading:url)
        precondition(partial.length == 16000*10, "A partial recording must already have a valid WAV header")
        try writer.append(Data(count:16000*2*125))
        let full = try AVAudioFile(forReading:url)
        precondition(full.length == 16000*135, "Meeting audio must exceed the dictation 90-second limit")
        precondition(full.fileFormat.sampleRate == 16000 && full.fileFormat.channelCount == 1)
        let attrs = try FileManager.default.attributesOfItem(atPath:url.path)
        precondition((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        writer.close()
        print("Meeting WAV passed: incremental crash-recoverable header, 135 seconds, 16 kHz mono, private permissions")
    }
}
