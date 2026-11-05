// A separate, permission-free host exercises the real updater without touching freetalk.
import AppKit
import CryptoKit

final class UpdateTestHost: NSObject, NSApplicationDelegate {
    let updater = AppUpdater()
    let info = Bundle.main.infoDictionary!
    var previousPhase = "", acted = Set<String>()
    var resultURL: URL { URL(fileURLWithPath:info["FTTestResult"] as! String) }
    var scenario: String { info["FTTestScenario"] as! String }
    func event(_ message: String) {
        let path = resultURL.appendingPathExtension("log")
        let data = (message+"\n").data(using:.utf8)!
        if let file = try? FileHandle(forWritingTo:path) { file.seekToEndOfFile(); file.write(data); try? file.close() }
        else { try? data.write(to:path) }
    }
    func finish(_ outcome: String) {
        let data = try! JSONSerialization.data(withJSONObject:["outcome":outcome,"message":updater.message])
        try! data.write(to:resultURL,options:.atomic)
        NSApp.terminate(nil)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        event("launched version \(info["CFBundleVersion"]!)")
        if scenario == "install", info["CFBundleVersion"] as? String == "2" { finish("installed-and-relaunched"); return }
        updater.onChange = { [weak self] in self?.changed() }
        updater.start(checkAtLaunch:false)
        updater.check()
        DispatchQueue.main.asyncAfter(deadline:.now()+50) { self.finish("timeout") }
    }
    func changed() {
        let phase = String(describing:updater.phase)
        if phase != previousPhase { event(phase+": "+updater.message); previousPhase = phase }
        switch updater.phase {
        case .available:
            guard acted.insert("download").inserted else { return }
            DispatchQueue.main.async { self.updater.primaryAction() }
        case .ready:
            guard acted.insert("install").inserted else { return }
            DispatchQueue.main.async { self.updater.primaryAction() }
        case .downloading where scenario == "cancel" && (updater.fraction ?? 0) > 0:
            guard acted.insert("cancel").inserted else { return }
            DispatchQueue.main.async { self.updater.cancel(); self.finish("cancelled") }
        case .failed:
            DispatchQueue.main.async { self.finish("rejected") }
        case .idle where scenario == "latest" && updater.lastChecked != nil:
            DispatchQueue.main.async { self.finish("already-latest") }
        default: break
        }
    }
}

@main struct UpdateIntegrationMain {
    static func main() throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--make-test-key" {
            let key = Curve25519.Signing.PrivateKey()
            let path = URL(fileURLWithPath:CommandLine.arguments[2])
            try key.rawRepresentation.base64EncodedData().write(to:path)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
            print(key.publicKey.rawRepresentation.base64EncodedString()); return
        }
        let app = NSApplication.shared
        let delegate = UpdateTestHost()
        app.setActivationPolicy(.accessory); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
