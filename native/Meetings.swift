import AppKit
import AVFoundation
import Security

enum MeetingKeychain {
    static let service = "io.github.zacklinkk.freetalk.meetings"
    static func read(endpoint: String) -> String? {
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,
            kSecAttrAccount as String:endpoint,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data:data,encoding:.utf8)
    }
    static func save(_ key: String, endpoint: String) throws {
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:endpoint]
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            guard SecItemAdd(add as CFDictionary,nil) == errSecSuccess else { throw VoiceError.message("无法将 API Key 保存到钥匙串") }; return
        }
        guard status == errSecSuccess else { throw VoiceError.message("钥匙串更新失败（\(status)）") }
    }
}

final class MeetingController: NSObject {
    unowned let app: AppDelegate
    let recorder = Recorder()
    lazy var downloads = ModelSetup(support:app.support,resources:Bundle.main.resourceURL!,catalogName:"meeting-catalog.json")
    var settings: [String: Any] = ["enabled":false,"diarization":false,"summary_mode":"local","retain_audio":false]
    var onChange: (() -> Void)?
    var onComplete: ((String) -> Void)?
    private(set) var recording = false, processing = false, preparing = false
    var busy: Bool { recording || processing || preparing || downloads.busy }
    private(set) var message = "启用后可导入录音或使用麦克风。已有模型可直接生成初稿。"
    private(set) var fraction: Double?
    private var writer: MeetingWAVWriter?
    private let recordingHUD = RecordingHUD()
    private var activeID: String?
    private var request = UUID()
    private var recordingDeviceUID: String?
    private var startupTimeout: Timer?
    var enabled: Bool { settings["enabled"] as? Bool == true }
    var root: URL { app.support.appendingPathComponent("meetings",isDirectory:true) }
    init(app: AppDelegate) {
        self.app = app; super.init()
        if let data = try? Data(contentsOf:app.support.appendingPathComponent("meeting-settings.json")),
           let saved = try? JSONSerialization.jsonObject(with:data) as? [String:Any] { settings.merge(saved) { _, new in new } }
    }
    func connect() {
        recordingHUD.onStop = { [weak self] in self?.stopRecording() }
        recordingHUD.onCancel = { [weak self] in self?.stopRecording(process:false) }
        downloads.onChange = { [weak self] in self?.onChange?(); self?.app.refreshUI() }
        downloads.onComplete = { [weak self] in
            guard let self = self else { return }; self.app.reloadModel(); self.message = "说话人模型已就绪，只在处理会议时加载。"; self.onChange?()
        }
        app.worker.onMeetingProgress = { [weak self] event in
            guard let self = self, event["meeting_id"] as? String == self.activeID else { return }
            self.message = event["message"] as? String ?? self.message
            if let done = event["completed"] as? Double, let total = event["total"] as? Double, total > 0 { self.fraction = min(1,max(0,done/total)) }
            else { self.fraction = nil }
            self.onChange?()
            if event["stage"] as? String == "transcript-ready", let id = self.activeID { self.onComplete?(id) }
        }
    }
    func saveSettings() throws {
        // Credentials are stored only in Keychain, never JSON or exported meeting files.
        for key in ["api_key","sk","token"] { settings.removeValue(forKey:key) }
        try write(settings,to:app.support.appendingPathComponent("meeting-settings.json"))
    }
    private func write(_ value: [String:Any], to url: URL) throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    func directory(_ id: String) -> URL { root.appendingPathComponent(id,isDirectory:true) }
    func entries() -> [[String:Any]] {
        let paths = (try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)) ?? []
        return paths.compactMap { path -> [String:Any]? in
            guard path.lastPathComponent.range(of:"^[0-9a-f]{32}$",options:.regularExpression) != nil,
                  let data = try? Data(contentsOf:path.appendingPathComponent("manifest.json")),
                  let item = try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return nil }
            return item
        }.sorted { ($0["created_at"] as? String ?? "") > ($1["created_at"] as? String ?? "") }
    }
    private func create(title: String, source: String) throws -> String {
        let id = UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
        let item: [String:Any] = ["schema":"freetalk.meeting.v1","id":id,"title":String(title.prefix(200)),
            "created_at":ISO8601DateFormatter().string(from:Date()),"source":source,"status":"created","audio_retained":false,"warnings":[]]
        try write(item,to:directory(id).appendingPathComponent("manifest.json")); return id
    }
    private func mark(_ id: String, status: String, error: String? = nil) {
        let url = directory(id).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf:url), var item = try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return }
        item["status"] = status; item["error"] = error
        item["audio_retained"] = FileManager.default.fileExists(atPath:directory(id).appendingPathComponent("audio.wav").path)
        try? write(item,to:url)
    }
    var cloudConfigured: Bool {
        let enabled = settings["cloud_enabled"] as? Bool ?? (settings["summary_mode"] as? String == "cloud")
        return enabled && !(settings["base_url"] as? String ?? "").isEmpty && !(settings["model"] as? String ?? "").isEmpty
    }
    func available() throws {
        guard enabled else { throw VoiceError.message("请先启用会议功能") }
        guard !busy, app.phase == .idle, !app.inserter.busy, !app.modelSetup.busy, !app.appUpdater.installing else { throw VoiceError.message("请先结束当前录音、处理或下载") }
        guard app.worker.ready else { throw VoiceError.message("请先准备本地模型，或等待模型加载完成") }
        if settings["diarization"] as? Bool == true,
           downloads.models.first?.filesPresent(config:app.config) != true { throw VoiceError.message("请先下载说话人模型，或关闭说话人区分") }

    }
    func showError(_ error: Error) { message = error.localizedDescription; onChange?() }
    func showMessage(_ text: String) { message = text; onChange?() }
    func importAudio() {
        do { try available() } catch { showError(error); return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = "导入会议录音"; panel.message = "WAV、M4A、MP3、FLAC。音频只在本机转写。配置云端增强后，仅发送基础纪要和相关引文。"
        panel.beginSheetModal(for:app.window) { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            do { try self.available(); let id = try self.create(title:url.deletingPathExtension().lastPathComponent,source:"file"); self.process(id,audio:url) }
            catch { self.showError(error) }
        }
    }
    func startRecording(title: String) {
        do {
            try available()
            guard AVCaptureDevice.authorizationStatus(for:.audio) == .authorized else { app.requestMic(); throw VoiceError.message("请允许麦克风后再次开始会议录音") }
            let uid = UserDefaults.standard.bool(forKey:"micFollowSystem") ? nil : UserDefaults.standard.string(forKey:"micUID")
            guard let device = MicDevices.selected(uid:uid,devices:MicDevices.all()) else { throw VoiceError.message("没有可用麦克风") }
            let id = try create(title:title.isEmpty ? "会议 " + DateFormatter.localizedString(from:Date(),dateStyle:.short,timeStyle:.short) : title,source:"microphone")
            activeID = id; request = UUID(); let token = request
            writer = try MeetingWAVWriter(url:directory(id).appendingPathComponent("audio.wav"))
            preparing = true; recordingDeviceUID = device.uid; message = "正在打开 \(device.name)…"; app.refreshUI(); onChange?()
            recordingHUD.showMeeting(shortcut: app.hotkey.meetingBinding.display)
            recorder.onChunk = { [weak self] data in
                guard let self = self, self.request == token else { return }
                do { try self.writer?.append(data) } catch { self.stopRecording(process:false); self.showError(error) }
            }
            recorder.onLevel = { [weak self] level, seconds in
                guard let self = self, self.request == token else { return }
                self.recordingHUD.updateMeeting(level:level,seconds:seconds)
                self.message = String(format:"正在录音 %02d:%02d · %@ · 结束后生成会议资料",Int(seconds)/60,Int(seconds)%60,device.name); self.onChange?()
                if seconds >= 8*3600 { self.stopRecording() }
            }
            recorder.onError = { [weak self] message in self?.stopRecording(process:false); self?.message = message; self?.onChange?() }
            startupTimeout = Timer.scheduledTimer(withTimeInterval:20,repeats:false) { [weak self] _ in
                guard let self = self, self.preparing, self.request == token else { return }; self.stopRecording(process:false); self.message = "麦克风启动超时，录音未开始"; self.onChange?()
            }
            recorder.start(device:device) { [weak self] result in
                guard let self = self, self.request == token else { return }; self.startupTimeout?.invalidate()
                switch result {
                case .success: self.preparing = false; self.recording = true; self.mark(id,status:"recording"); self.app.refreshUI(); self.onChange?()
                case .failure(let error): self.recordingHUD.hide(); self.preparing = false; self.writer?.close(); self.writer = nil; self.mark(id,status:"failed",error:error.localizedDescription); self.showError(error); self.app.refreshUI()
                }
            }
        } catch { showError(error) }
    }
    func stopRecording(process: Bool = true) {
        guard recording || preparing, let id = activeID else { return }
        recordingHUD.finishMeeting(process ? "正在生成本地会议资料" : "已暂停，可在会议资料中继续处理")
        recording = false; preparing = false; processing = true; startupTimeout?.invalidate()
        recorder.onLevel = nil; recorder.onError = nil
        recorder.stop { [weak self] seconds,_ in
            guard let self = self else { return }; self.writer?.close(); self.writer = nil; self.recorder.onChunk = nil
            self.processing = false; self.recordingDeviceUID = nil
            if process && seconds >= 0.5 { self.process(id,audio:self.directory(id).appendingPathComponent("audio.wav")) }
            else { self.mark(id,status:"interrupted",error:"录音已保存，可在列表选择后继续处理"); self.message = "录音已停止并保留，可稍后继续处理。"; self.onComplete?(id); self.onChange?(); self.app.refreshUI() }
        }
        message = "正在保存录音…"; onChange?(); app.refreshUI()
    }
    func process(_ id: String, audio: URL? = nil) {
        activeID = id; request = UUID(); let token = request
        processing = true; fraction = nil; message = "正在准备会议资料…"; app.correctionLearner.stop(); app.refreshUI(); onChange?()
        onComplete?(id)
        var payload: [String:Any] = ["support":app.support.path,"meeting_id":id]
        payload["hotwords"] = (try? app.vocabularyStore.load()) ?? []
        if let audio = audio { payload["audio_path"] = audio.path }
        if cloudConfigured { payload["api_key"] = MeetingKeychain.read(endpoint:settings["base_url"] as? String ?? "") ?? "" }
        app.worker.request("meeting",payload) { [weak self] result in
            guard let self = self, self.request == token else { return }; self.processing = false; self.fraction = nil
            switch result {
            case .success:
                let manifest = (try? Data(contentsOf:self.directory(id).appendingPathComponent("manifest.json"))).flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] }
                self.message = manifest?["deep_status"] as? String == "failed" ? "本地纪要、原稿和脑图已生成；云端深度整理失败，可检查配置后重试。" : "会议资料已生成。可查看、导出或交给 agent。"
            case .failure(let error): self.message = "会议处理未完成：\(error.localizedDescription)"; self.mark(id,status:"failed",error:error.localizedDescription)
            }
            self.app.refreshUI(); self.onComplete?(id); self.onChange?()
        }
    }
    func cancel() {
        if recording || preparing { stopRecording(process:false); return }
        if downloads.busy { downloads.cancel(); return }
        guard processing else { return }
        request = UUID(); app.worker.stop(); processing = false
        if let id = activeID { mark(id,status:"interrupted",error:"处理已停止，原稿进度保留"); onComplete?(id) }
        message = "已停止处理。录音和已完成的转写仍保留，可继续处理。"; fraction = nil; app.reloadModel(); onChange?()
    }
    func checkDevice() {
        if (recording || preparing), let uid = recordingDeviceUID, !MicDevices.all().contains(where: { $0.uid == uid }) { stopRecording(process:false) }
    }
    func checkAudio() {
        guard recording else { return }
        recorder.checkRunning { [weak self] active in if !active { self?.stopRecording(process:false) } }
    }
}
