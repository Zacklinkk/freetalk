import Foundation

final class MeetingWAVWriter {
    private let handle: FileHandle
    private var bytes: UInt32 = 0
    init(url: URL) throws {
        FileManager.default.createFile(atPath:url.path,contents:Data(),attributes:[.posixPermissions:0o600])
        handle = try FileHandle(forWritingTo:url)
        try writeHeader()
    }
    private func writeHeader() throws {
        var data = Data()
        func chars(_ s: String) { data.append(Data(s.utf8)) }
        func number<T: FixedWidthInteger>(_ n: T) { var x = n.littleEndian; withUnsafeBytes(of:&x) { data.append(contentsOf:$0) } }
        chars("RIFF"); number(UInt32(36)+bytes); chars("WAVEfmt "); number(UInt32(16)); number(UInt16(1)); number(UInt16(1))
        number(UInt32(16000)); number(UInt32(32000)); number(UInt16(2)); number(UInt16(16)); chars("data"); number(bytes)
        try handle.seek(toOffset:0); try handle.write(contentsOf:data)
    }
    func append(_ data: Data) throws {
        guard UInt64(bytes)+UInt64(data.count) < UInt64(UInt32.max)-44 else { throw VoiceError.message("录音已达到单文件容量上限") }
        try handle.seekToEnd(); try handle.write(contentsOf:data); bytes += UInt32(data.count)
        // A crash or battery loss still leaves a valid, recoverable WAV file.
        try writeHeader(); try handle.synchronize()
    }
    func close() { try? handle.synchronize(); try? handle.close() }
    deinit { close() }
}

