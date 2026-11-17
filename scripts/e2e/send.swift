// Posts one command to an end-to-end build of freetalk and prints its reply
// (see native/E2EHooks.swift). usage: send <support dir> <command> [key=value ...]
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else { FileHandle.standardError.write(Data("usage: send <support dir> <command> [key=value ...]\n".utf8)); exit(2) }
let reply = URL(fileURLWithPath: args[1]).appendingPathComponent("e2e/reply.json")
let seq = UUID().uuidString
var info: [String: String] = ["command": args[2], "seq": seq]
for pair in args.dropFirst(3) {
    let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
    if parts.count == 2 { info[parts[0]] = parts[1] }
}
DistributedNotificationCenter.default().postNotificationName(Notification.Name("io.github.zacklinkk.freetalk.e2e"), object: nil, userInfo: info, deliverImmediately: true)
let deadline = Date().addingTimeInterval(Double(ProcessInfo.processInfo.environment["E2E_TIMEOUT"] ?? "") ?? 40)
while Date() < deadline {
    if let data = try? Data(contentsOf: reply), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], value["seq"] as? String == seq {
        FileHandle.standardOutput.write(data); exit(0)
    }
    Thread.sleep(forTimeInterval: 0.2)
}
FileHandle.standardError.write(Data("no reply to \(args[2])\n".utf8)); exit(1)
