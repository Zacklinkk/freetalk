import AppKit
import AVFoundation
import IOKit.ps

/// Keeps each opted-in dictation and the user's review together. The recorder
/// callback never waits for a filesystem sync.
final class PersonalLearning: NSObject {
    unowned let app: AppDelegate
    private let io = DispatchQueue(label: "freetalk.learning.audio", qos: .utility)
    private var writer: MeetingWAVWriter? // only touched on io
    private var capturing: UUID?
    private let labels = [
        ("retain", "留存本次口述的录音和学习资料"),
        ("train", "允许本地微调"),
        ("voice", "允许用本人音色生成已批准的练习样本"),
        ("idle", "接电空闲时训练"),
        ("auto", "自动启用已试用且通过验收的候选")
    ]
    private var flags: [String: Bool] = [:]
    private var controls: [String: NSButton] = [:]
    private let status = NSTextField(wrappingLabelWithString: "")
    private let historySize = NSPopUpButton()
    private var job: Process?
    private var monitor: Timer?, scheduler: Timer?
    private var wasIdleJob = false
    private var lastIdleAttempt = Date.distantPast
    private var idleLane: String { UserDefaults.standard.bool(forKey:"lastIdleWasCleanup") ? "train-asr" : "train" }
    private var player: AVAudioPlayer?
    private var reviewAudio: URL?
    private var pendingStart: (() -> Void)?
    private var restarting = false
    private var checkingLabels = false
    private var shuttingDown = false
    var busy: Bool { job != nil || restarting }
    private var root: URL { app.support.appendingPathComponent("learning", isDirectory:true) }
    private var samples: URL { root.appendingPathComponent("samples", isDirectory:true) }
    private var preferences: URL { app.support.appendingPathComponent("learning-settings.json") }

    init(app: AppDelegate) {
        self.app = app
        super.init()
        if let data = try? Data(contentsOf: preferences), let value = try? JSONDecoder().decode([String:Bool].self, from:data) { flags = value }
    }
    func historyControls() -> NSView {
        historySize.addItems(withTitles: VoiceHistoryStore.capacities.map { String($0) + " 条" })
        historySize.selectItem(at: VoiceHistoryStore.capacities.firstIndex(of: app.historyStore.capacity) ?? 0)
        historySize.setAccessibilityLabel("转写历史保留条数")
        historySize.target = self; historySize.action = #selector(historyChanged)
        return app.row([app.label("保留最近"), historySize])
    }
    @objc private func historyChanged() { app.historyStore.setCapacity(VoiceHistoryStore.capacities[historySize.indexOfSelectedItem]) }

    func makeCard() -> NSView {
        var views: [NSView] = []
        for (key,title) in labels {
            let button = NSButton(checkboxWithTitle:title, target:self, action:#selector(change(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(key); button.state = flags[key] == true ? .on : .off
            controls[key] = button; views.append(button)
        }
        let start = NSButton(title:"训练整理",target:self,action:#selector(train))
        let trial = NSButton(title:"试用整理",target:self,action:#selector(trialCandidate))
        let undo = NSButton(title:"恢复整理",target:self,action:#selector(rollback))
        let folder = NSButton(title:"学习文件夹",target:self,action:#selector(showFiles))
        status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize:12)
        status.stringValue = "在转写历史里核对发送稿。音频和模型权重只保存在本机。"
        let asr = NSButton(title:"训练识别",target:self,action:#selector(trainASR))
        let trialASR = NSButton(title:"试用识别",target:self,action:#selector(tryASR))
        let undoASR = NSButton(title:"恢复识别",target:self,action:#selector(resetASR))
        views += [app.row([start,trial,undo]),app.row([asr,trialASR,undoASR]),folder,status]
        return app.card("个人模型学习", views:views)
    }
    @objc private func change(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        let previous = flags
        flags[key] = sender.state == .on
        do {
            try JSONEncoder().encode(flags).write(to:preferences,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:preferences.path)
        } catch {
            flags = previous; sender.state = flags[key] == true ? .on : .off
            status.stringValue = "设置保存失败：" + error.localizedDescription; return
        }
        if key == "retain", flags[key] != true, let id = capturing { discardAudio(id) }
        if flags["train"] != true || (wasIdleJob && flags["idle"] != true) { interrupt() }
    }
    @objc private func showFiles() {
        do { try FileManager.default.createDirectory(at:samples,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]); NSWorkspace.shared.open(root) }
        catch { status.stringValue = error.localizedDescription }
    }
    private func sample(_ id: String) -> URL { samples.appendingPathComponent(id,isDirectory:true) }
    private func note(_ text: String) { DispatchQueue.main.async { [weak self] in self?.status.stringValue = text } }

    func beginAudio(_ id: UUID) {
        guard flags["retain"] == true, let target = app.target, WindowText.allowed(bundle:target.bundle) else { return }
        if let previous = capturing { discardAudio(previous) }
        let dir = sample(id.uuidString)
        capturing = id
        io.async {
            do {
                let free = try self.app.support.resourceValues(forKeys:[.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
                guard free > 512 * 1024 * 1024 else { self.note("磁盘余量不足，本次仅保留文字历史。"); return }
                try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                self.writer = try MeetingWAVWriter(url:dir.appendingPathComponent("audio.wav"))
            } catch { self.note("本次学习录音无法保存：" + error.localizedDescription) }
        }
    }
    func append(_ data: Data, id: UUID) {
        guard capturing == id else { return }
        io.async {
            do { try self.writer?.append(data) }
            catch {
                self.writer?.close(); self.writer=nil
                try? FileManager.default.removeItem(at:self.sample(id.uuidString).appendingPathComponent("audio.wav"))
                self.note("学习录音写入失败：" + error.localizedDescription)
            }
        }
    }
    func finishAudio(id: UUID, keep: Bool) {
        guard capturing == id else { return }
        capturing = nil
        io.async {
            self.writer?.close(); self.writer=nil
            if !keep { try? FileManager.default.removeItem(at:self.sample(id.uuidString)) }
        }
    }
    func discardAudio(_ id: UUID) { finishAudio(id:id, keep:false) }
    private func store(_ entry: VoiceHistoryEntry, explicit: Bool) {
        guard UUID(uuidString:entry.id) != nil else { return }
        let dir = sample(entry.id)
        io.async {
            do {
                if explicit { try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]) }
                else if !FileManager.default.fileExists(atPath:dir.path) { return }
                let file = dir.appendingPathComponent("record.json")
                let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
                try enc.encode(entry).write(to:file,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            } catch { self.note("学习记录保存失败：" + error.localizedDescription) }
        }
    }
    func updated(_ entry: VoiceHistoryEntry) {
        if flags["retain"] == true { store(entry, explicit:false) }
    }
    func review(_ entry: VoiceHistoryEntry) {
        guard flags["retain"] == true else {
            let alert=NSAlert(); alert.messageText="先开启学习资料留存"; alert.informativeText="在「常用词与学习 → 个人模型学习」中开启后，可核对最终发送稿。"; alert.runModal(); return
        }
        let alert = NSAlert(); alert.messageText = "核对实际发送的文字"
        alert.informativeText = "粘贴或修改为你实际发送的版本。只有听过本条录音、确认两者逐句对应时，才勾选语音识别训练。"
        let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:420,height:105)); scroll.hasVerticalScroller=true
        let field = NSTextView(frame:scroll.bounds); field.isRichText=false; field.autoresizingMask = .width
        field.isVerticallyResizable=true; field.textContainer?.widthTracksTextView=true; scroll.documentView=field
        field.string = entry.reviewedFinal ?? entry.editedText ?? entry.text
        let audio = sample(entry.id).appendingPathComponent("audio.wav")
        reviewAudio = FileManager.default.fileExists(atPath:audio.path) ? audio : nil
        let play = NSButton(title:"试听录音",target:self,action:#selector(playReview)); play.isEnabled = reviewAudio != nil
        let aligned = NSButton(checkboxWithTitle:"已核对，这份文字与录音内容逐句一致",target:nil,action:nil)
        aligned.isEnabled = play.isEnabled; aligned.state = entry.audioAligned == true && play.isEnabled ? .on : .off
        let stack = NSStackView(views:[scroll,app.row([play,aligned])]); stack.orientation = .vertical; stack.alignment = .leading
        scroll.widthAnchor.constraint(equalToConstant:420).isActive=true; scroll.heightAnchor.constraint(equalToConstant:105).isActive=true
        stack.frame = NSRect(x:0,y:0,width:440,height:142); alert.accessoryView=stack
        alert.addButton(withTitle:"保存核对稿"); alert.addButton(withTitle:"取消")
        let accepted = alert.runModal() == .alertFirstButtonReturn
        player?.stop(); player=nil; reviewAudio=nil
        let final = field.string.trimmingCharacters(in:.whitespacesAndNewlines)
        guard accepted,!final.isEmpty else { return }
        app.annotateHistory(entry.id) { $0.reviewedFinal=final; $0.audioAligned=aligned.state == .on }
        if let saved = app.historyStore.entries.first(where:{ $0.id == entry.id }) { store(saved, explicit:true) }
        lastIdleAttempt = .distantPast
    }
    @objc private func playReview() {
        guard let url = reviewAudio else { return }
        do { player=try AVAudioPlayer(contentsOf:url); player?.play() } catch { note(error.localizedDescription) }
    }

    private var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:CGEventType(rawValue:UInt32.max)!)
    }
    private var enoughResources: Bool {
        guard let source = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let power = IOPSGetProvidingPowerSourceType(source)?.takeUnretainedValue(),
              (power as String) == kIOPSACPowerValue,
              ProcessInfo.processInfo.thermalState.rawValue <= ProcessInfo.ThermalState.fair.rawValue,
              let free = try? app.support.resourceValues(forKeys:[.volumeAvailableCapacityKey]).volumeAvailableCapacity,
              free > 3 * 1024 * 1024 * 1024 else { return false }
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue:stats)/MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to:&stats) { ptr in
            ptr.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { host_statistics64(mach_host_self(),HOST_VM_INFO64,$0,&count) }
        }
        return result == KERN_SUCCESS && (UInt64(stats.free_count)+UInt64(stats.inactive_count))*UInt64(vm_kernel_page_size) > 2*1024*1024*1024
    }
    private var appIdle: Bool {
        app.phase == .idle && !app.meetings.busy && !app.inserter.busy && !app.modelSetup.busy &&
            !app.appUpdater.installing && !app.promptEditor.checking && !app.promptTuning.busy && !app.nightly.busy
    }
    func schedule() {
        scheduler = Timer.scheduledTimer(withTimeInterval:60,repeats:true) { [weak self] _ in
            guard let self, self.flags["train"] == true,self.flags["idle"] == true,!self.busy,self.appIdle,
                  self.app.worker.ready,self.idleSeconds >= 600,self.enoughResources,
                  Date().timeIntervalSince(self.lastIdleAttempt)>6*3600 else { return }
            self.lastIdleAttempt=Date()
            let lane = self.idleLane
            UserDefaults.standard.set(lane == "train", forKey:"lastIdleWasCleanup")
            self.launch(lane,idle:true)
        }
    }
    @objc private func train() { launch("train") }
    @objc private func trainASR() { launch("train-asr") }
    @objc private func tryASR() { launch("trial-asr") }
    @objc private func resetASR() { launch("rollback-asr") }
    @objc private func trialCandidate() { launch("trial") }
    @objc private func rollback() { launch("rollback") }
    private func launch(_ action: String, idle: Bool = false, checked: Bool = false) {
        guard !busy,appIdle else { status.stringValue="请先结束当前处理。"; return }
        guard action.hasPrefix("rollback") || flags["train"] == true else { status.stringValue="请先允许本地微调。"; return }
        if action.hasPrefix("train") && !checked {
            guard !checkingLabels else { return }
            checkingLabels=true
            let directory = samples
            DispatchQueue.global(qos:.utility).async { [weak self] in
                let files=(try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? []
                let count=files.lazy.filter { url in
                    guard let data=try? Data(contentsOf:url.appendingPathComponent("record.json")),
                          let obj=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return false }
                    return obj["reviewedFinal"] as? String != nil
                }.prefix(12).count
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.checkingLabels=false
                    guard count >= 12 else {
                        self.status.stringValue="训练至少需要跨日期的 12 条核对稿。可在转写历史中核对。"; return
                    }
                    guard !self.shuttingDown, !idle || (self.flags["idle"] == true && self.idleSeconds >= 600 && self.enoughResources) else { return }
                    self.launch(action,idle:idle,checked:true)
                }
            }
            return
        }
        guard let python = app.config["python"] as? String, let resources = Bundle.main.resourceURL else { return }
        let task=Process(), pipe=Pipe()
        task.executableURL=URL(fileURLWithPath:python)
        task.arguments=["-u",resources.appendingPathComponent("python/personal_learning.py").path,action,"--support",app.support.path]
        var env=ProcessInfo.processInfo.environment; env["HF_HUB_OFFLINE"]="1"; env["PYTHONDONTWRITEBYTECODE"]="1"; task.environment=env
        task.standardOutput=pipe; task.standardError=FileHandle.nullDevice
        job=task; wasIdleJob=idle; app.worker.stop(); status.stringValue="正在处理本地候选…"
        task.terminationHandler = { [weak self] completed in
            let data=pipe.fileHandleForReading.readDataToEndOfFile()
            let message=String(decoding:data,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard let self,self.job === completed else { return }
                self.monitor?.invalidate(); self.job=nil
                self.status.stringValue = message.components(separatedBy:"\n").last.flatMap { $0.isEmpty ? nil : $0 } ?? "任务已结束（\(completed.terminationStatus)）"
                if !self.shuttingDown { self.restarting=true; self.app.reloadModel() }
            }
        }
        do {
            try task.run()
            if idle {
                monitor=Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in
                    guard let self else { return }
                    if self.idleSeconds<5 || !self.appIdle || !self.enoughResources { self.interrupt() }
                }
            }
        } catch { self.job=nil; app.reloadModel(); status.stringValue=error.localizedDescription }
    }
    func modelState(_ ready: Bool, message: String) {
        if ready {
            restarting=false
            let start=pendingStart; pendingStart=nil
            if let start { DispatchQueue.main.async(execute:start) }
        } else if restarting && !message.contains("正在加载") {
            restarting=false; pendingStart=nil
        }
    }
    private func interrupt() {
        if let job, job.isRunning {
            job.terminate(); status.stringValue="正在保留上一步进度并恢复语音模型…"
        }
    }
    func preemptForInput(_ start: @escaping () -> Void) -> Bool {
        guard busy else { return false }
        if pendingStart != nil { pendingStart=nil; app.setStatus("已取消等待录音。"); return true }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let snapshot = try? InputSnapshot.capture()
        let requested = ProcessInfo.processInfo.systemUptime
        pendingStart = { [weak self] in
            guard let self else { return }
            guard ProcessInfo.processInfo.systemUptime-requested<60,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier==pid, snapshot?.unchanged() != false
            else { self.app.setStatus("输入位置已经变化。请在目标输入框重新开始。"); return }
            start()
        }
        interrupt()
        app.setStatus("正在恢复语音模型，看到录音浮窗后开始说话。再按一次可取消。")
        return true
    }
    func shutdown() {
        shuttingDown=true; scheduler?.invalidate(); monitor?.invalidate(); interrupt()
        if let id=capturing { discardAudio(id) }
        io.sync {}
    }
}
