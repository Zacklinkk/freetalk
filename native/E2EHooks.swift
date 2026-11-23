#if E2E_HOOKS
import AppKit
import AVFoundation
import ApplicationServices

/// Test-only hooks for the in-app end-to-end checks (scripts/e2e). Compiled
/// only with -D E2E_HOOKS (scripts/build-e2e.sh); release builds never
/// contain them. Commands arrive as distributed notifications named
/// `io.github.zacklinkk.freetalk.e2e` with a `command` key; each reply is
/// written to <support>/e2e/reply.json with the request's `seq`.
///
/// The hooks act as a user would: they post the shortcut's key events (so the
/// real event tap fires), read and edit the focused field. The test plays the
/// voice itself. Reading, editing and recognizing text are limited to the
/// test apps, so a check can never touch the user's own documents.
final class E2EHooks: NSObject {
    static let name = Notification.Name("io.github.zacklinkk.freetalk.e2e")
    static let testApps: Set<String> = ["com.apple.TextEdit"]
    unowned let app: AppDelegate
    private let began = Date()
    private var reply: URL { app.support.appendingPathComponent("e2e/reply.json") }

    init(app: AppDelegate) {
        self.app = app; super.init()
        // The cloud key from a private file the test wrote (scripts/e2e/run.py) and
        // deletes after launch, so nightly maintenance never waits on the Keychain.
        let base = CloudEditorSettings.load().baseURL
        if let path = ProcessInfo.processInfo.environment["FREETALK_E2E_CLOUD_FILE"], !base.isEmpty,
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let key = value["key"] as? String, !key.isEmpty {
            CloudCredentialStore.seed(base, CloudCredentials(key: key, headers: value["headers"] as? [String: String] ?? [:]))
        }
        if ProcessInfo.processInfo.environment["FREETALK_E2E_LATENCY"] == "1", ProcessInfo.processInfo.environment["FREETALK_E2E_SUPPORT"] != nil { E2ELatency(app:app).start() }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(received(_:)), name: Self.name, object: nil, suspensionBehavior: .deliverImmediately)
    }

    @objc private func received(_ note: Notification) {
        let info = note.userInfo ?? [:]
        let seq = info["seq"] as? String ?? "", command = info["command"] as? String ?? ""
        var result: [String: Any] = ["seq": seq, "command": command]
        switch command {
        case "status": result.merge(status()) { _, new in new }
        case "key": result["posted"] = post(info["binding"] as? String ?? "dictation")
        case "read": result.merge(readFocused()) { _, new in new }
        case "edit": result.merge(edit(info["value"] as? String ?? "")) { _, new in new }
        case "ocr": recognize(expect: (info["expect"] as? String ?? "").components(separatedBy: "|").filter { !$0.isEmpty }, seq: seq); return
        case "history": result["entries"] = history()
        case "cancel": app.cancelRecording(); result["phase"] = "\(app.phase)"
        case "nightly": app.nightly.runNow(); result["started"] = true
        case "nightly-due":
            // The automatic run, as if it were `hour` o'clock tomorrow and nobody had dictated since today.
            let hour = Int(info["hour"] as? String ?? "1") ?? 1
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
            app.nightly.runIfDue(now: Calendar.current.date(byAdding: .hour, value: hour, to: tomorrow)!)
            result["started"] = app.nightly.busy
        case "nightly-status": result["busy"] = app.nightly.busy; result["report"] = UserDefaults.standard.string(forKey: "nightlyReport") ?? ""
        case "meeting-start": app.meetings.startRecording(title: "E2E 双轨测试"); result["started"] = true
        case "meeting-option":
            app.meetings.settings["system_audio"] = info["system_audio"] as? String == "true"
            do { try app.meetings.saveSettings(); result["system_audio"] = app.meetings.recordsSystemAudio } catch { result["error"] = error.localizedDescription }
        case "meeting-stop": app.meetings.stopRecording(); result["stopped"] = true
        case "meeting": result.merge(meeting()) { _, new in new }
        default: result["error"] = "unknown command"
        }
        write(result)
    }

    private func write(_ value: [String: Any]) {
        var value = value; value["written"] = ISO8601DateFormatter().string(from: Date())
        try? FileManager.default.createDirectory(at: reply.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: reply, options: .atomic) }
    }

    private func status() -> [String: Any] {
        let permissions = VoicePermissions.current(shortcutActive: app.hotkey.active, shortcutFailure: app.hotkey.failure)
        return ["accessibility": AXIsProcessTrusted(), "listen": CGPreflightListenEventAccess(), "post": CGPreflightPostEventAccess(),
                "screen": CGPreflightScreenCaptureAccess(), "microphone": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                "hotkey_active": app.hotkey.active, "hotkey_failure": app.hotkey.failure ?? "", "needs_guidance": permissions.needsGuidance,
                "worker_ready": app.worker.ready, "phase": "\(app.phase)", "status": app.statusText,
                "dictation_key": app.hotkey.binding.display, "translation_key": app.hotkey.translationBinding?.display ?? "",
                "meeting_key": app.hotkey.meetingBinding.display]
    }

    /// The binding's key events, posted to the HID stream like a keyboard would;
    /// only while a test app is in front, so a dictation never starts elsewhere.
    private func post(_ which: String) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, Self.testApps.contains(front) else { return false }
        // A locked screen would take the keys as password input.
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any], session["CGSSessionScreenIsLocked"] as? Bool == true { return false }
        let binding: HotkeyBinding? = which == "translation" ? app.hotkey.translationBinding : which == "meeting" ? app.hotkey.meetingBinding : app.hotkey.binding
        guard let binding = binding, let source = CGEventSource(stateID: .hidSystemState) else { return false }
        func flags(_ modifiers: [HotkeyModifier]) -> CGEventFlags {
            CGEventFlags(rawValue: modifiers.reduce(UInt64(0)) { $0 | $1.genericFlag.rawValue | $1.deviceBit })
        }
        func modifier(_ m: HotkeyModifier, down: Bool, held: [HotkeyModifier]) -> CGEvent? {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(m.rawValue), keyDown: down)
            event?.type = .flagsChanged; event?.flags = flags(down ? held : held.filter { $0 != m }); return event
        }
        var events: [CGEvent?] = []
        switch binding.trigger {
        case .modifierTap(let m):
            events = [modifier(m, down: true, held: [m]), modifier(m, down: false, held: [m])]
        case .chord(let key, let modifiers):
            events = modifiers.map { modifier($0, down: true, held: modifiers) }
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down); event?.flags = flags(modifiers); events.append(event)
            }
            events += modifiers.reversed().map { modifier($0, down: false, held: modifiers) }
        }
        for (index, event) in events.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(index)) { event?.post(tap: .cghidEventTap) }
        }
        return events.allSatisfy { $0 != nil }
    }

    private func focusedTestField() -> (AXUIElement, String)? {
        guard let front = NSWorkspace.shared.frontmostApplication, let bundle = front.bundleIdentifier, Self.testApps.contains(bundle),
              let element = focusedElement(front.processIdentifier) else { return nil }
        return (element, bundle)
    }

    private func readFocused() -> [String: Any] {
        guard let (element, bundle) = focusedTestField() else { return ["error": "the frontmost app is not a test app"] }
        return ["bundle": bundle, "role": axAttribute(element, kAXRoleAttribute) as? String ?? "",
                "value": String((axAttribute(element, kAXValueAttribute) as? String ?? "").prefix(4000))]
    }

    /// Replace the focused field's text, as if the user had edited it.
    private func edit(_ value: String) -> [String: Any] {
        guard let (element, bundle) = focusedTestField() else { return ["error": "the frontmost app is not a test app"] }
        let status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
        return ["bundle": bundle, "ax_error": status.rawValue]
    }

    private func recognize(expect: [String], seq: String) {
        guard let front = NSWorkspace.shared.frontmostApplication, let bundle = front.bundleIdentifier, Self.testApps.contains(bundle) else {
            write(["seq": seq, "command": "ocr", "error": "the frontmost app is not a test app"]); return
        }
        let started = Date()
        WindowText.recognize(pid: front.processIdentifier, bundle: bundle, title: "", anchor: nil) { [weak self] text in
            let found = expect.filter { text.contains($0) }
            self?.write(["seq": seq, "command": "ocr", "bundle": bundle, "permitted": WindowText.permitted, "characters": text.count,
                         "found": found, "missing": expect.filter { !found.contains($0) }, "seconds": Date().timeIntervalSince(started)])
        }
    }

    /// Dictations made since the hooks started; earlier ones belong to the user.
    private func history() -> [[String: Any]] {
        app.historyStore.entries.filter { $0.createdAt >= began }.prefix(10).map { entry in
            ["id": entry.id, "text": entry.text, "raw": entry.raw, "app": entry.targetApp, "insertion": entry.insertionStatus,
             "check": entry.insertionCheck ?? "", "cleanup": entry.cleanupStatus, "edited": entry.editedText ?? "",
             "learned": entry.learned ?? [], "learning_stop": entry.learningStop ?? ""]
        }
    }

    private func meeting() -> [String: Any] {
        // The test's support directory holds only test meetings; the newest is this run's.
        let newest = app.meetings.entries().first ?? [:]
        var result: [String: Any] = ["busy": app.meetings.busy, "message": app.meetings.message]
        for key in ["id", "status", "stage", "tracks", "system_offset_seconds", "echo_clauses_dropped", "segment_count", "error", "processing_seconds", "deep_status"] {
            if let value = newest[key] { result[key] = value }
        }
        if let id = newest["id"] as? String {
            let folder = app.meetings.directory(id)
            result["folder"] = folder.path
            result["files"] = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        }
        return result
    }
}
var e2eHooks: E2EHooks?
#endif
