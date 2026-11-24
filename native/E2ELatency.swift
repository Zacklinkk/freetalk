#if E2E_HOOKS
import AppKit

/// A replay stops through the normal recorder, worker and AX insertion path.
/// Only a marked, frontmost TextEdit document in an isolated test run is eligible.
final class E2ELatency {
    private unowned let app: AppDelegate
    private var timer: Timer?
    private var marker = "", expected = ""
    private var insertionOffset = 0
    private var clips: [URL] = [], results: [[String:Any]] = []
    private var running: UUID?
    private let began = Date()
    init(app: AppDelegate) { self.app=app }
    private var folder: URL { app.support.appendingPathComponent("e2e") }
    func start() {
        marker = (try? String(contentsOf:folder.appendingPathComponent("marker.txt"),encoding:.utf8)) ?? ""
        guard marker.hasPrefix("freetalk-latency-"), marker.count > 24 else { return }
        clips = ((try? FileManager.default.contentsOfDirectory(at:folder, includingPropertiesForKeys:nil)) ?? [])
            .filter { $0.pathExtension == "pcm" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !clips.isEmpty else { return }
        expected = marker
        persist("waiting-for-marked-document")
        timer = Timer.scheduledTimer(withTimeInterval:0.35,repeats:true) { _ in self.advance() }
    }
    private func persist(_ state: String) {
        let report: [String:Any] = ["state":state,"results":results]
        if let data=try? JSONSerialization.data(withJSONObject:report) {
            try? data.write(to:folder.appendingPathComponent("latency.json"),options:.atomic)
        }
    }
    private func finish(_ message: String) { timer?.invalidate(); timer=nil; persist(message) }
    private func advance() {
        guard Date().timeIntervalSince(began) < 600 else { finish("deadline"); return }
        guard app.worker.ready, app.phase == .idle, !app.inserter.busy else { return }
        if let id=running {
            guard let entry=app.historyStore.entries.first(where:{$0.id==id.uuidString}) else { return }
            guard let latency=entry.stopToInputSeconds else { finish(entry.insertionStatus); return }
            results.append(["clip":clips[results.count % clips.count].lastPathComponent,"seconds":latency,
                            "check":entry.insertionCheck ?? "", "stop_to_text":entry.stopToTextSeconds, "model_used":entry.modelUsed])
            expected = (expected as NSString).replacingCharacters(in:NSRange(location:insertionOffset,length:0),with:entry.text)
            running=nil; persist("running")
            if results.count == 20 { finish("complete"); return }
        }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier=="com.apple.TextEdit",
              let target=try? InputSnapshot.capture(), target.value==expected, target.range.length==0 else { return }
        let clip=clips[results.count % clips.count]
        guard let pcm=try? Data(contentsOf:clip), pcm.count>3200, pcm.count<=16000*2*20 else { finish("invalid PCM"); return }
        let id=UUID()
        insertionOffset=target.range.location
        running=id; app.session=id; app.target=target; app.currentEntry=nil; app.phase = .preparing
        app.tutorialSession=false; app.translating=false; app.partial=""
        app.worker.request("begin",["context":[:], "cleanup_policy":"auto"]) { result in
            guard case .success = result else { self.app.phase = .idle; self.finish("worker begin failed"); return }
            guard target.unchanged() else {
                self.app.phase = .idle; self.running=nil; self.persist("waiting for stable focus"); return
            }
            self.app.recorder.onChunk = { pcm in self.app.worker.request("chunk",["pcm":pcm.base64EncodedString()]) }
            self.app.recorder.loadReplayTail(pcm); self.app.phase = .recording
            self.app.stopRecording()
        }
    }
}
#endif
