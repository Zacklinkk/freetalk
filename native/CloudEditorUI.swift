import AppKit

/// Settings card for the optional cloud models: one service, a fast and a
/// strong model, and a switch per feature.
final class CloudEditorPanel: NSObject {
    unowned let app: AppDelegate
    let protocolPicker = NSPopUpButton()
    let baseURL = NSTextField(), model = NSTextField(), strongModel = NSTextField(), key = NSSecureTextField(), headers = NSTextField()
    let timeoutPicker = NSPopUpButton()
    let cleanup = NSButton(checkboxWithTitle: "口述整理（快模型；失败时自动改用本地模型）", target: nil, action: nil)
    let translation = NSButton(checkboxWithTitle: "翻译输入（快模型；关闭时用本地模型翻译）", target: nil, action: nil)
    let meetings = NSButton(checkboxWithTitle: "会议深度整理与写作（强模型；本地基础纪要始终保留）", target: nil, action: nil)
    let tuning = NSButton(checkboxWithTitle: "整理规则优化（强模型，在「常用词与学习」里手动运行）", target: nil, action: nil)
    let status = NSTextField(wrappingLabelWithString: "")
    private var testButton: NSButton!

    init(app: AppDelegate) { self.app = app; super.init() }

    func makeCard() -> NSView {
        let settings = CloudEditorSettings.load()
        protocolPicker.addItems(withTitles: CloudEditorSettings.protocols.map(\.1))
        protocolPicker.selectItem(at: CloudEditorSettings.protocols.firstIndex { $0.0 == settings.protocolName } ?? 0)
        protocolPicker.setAccessibilityLabel("云端接口协议")
        baseURL.placeholderString = "https://你的服务/v1"; baseURL.stringValue = settings.baseURL; baseURL.setAccessibilityLabel("云端 API 地址")
        model.placeholderString = "响应快的模型，用于口述整理和翻译"; model.stringValue = settings.model; model.setAccessibilityLabel("快模型名称")
        strongModel.placeholderString = "能力强的模型，用于规则优化和会议写作；留空则用快模型"; strongModel.stringValue = settings.strongModel
        strongModel.setAccessibilityLabel("强模型名称")
        key.placeholderString = "API Key · 留空保留钥匙串中的密钥"; key.setAccessibilityLabel("云端 API Key")
        headers.placeholderString = "可选 · 网关要求的额外请求头，JSON 对象"; headers.setAccessibilityLabel("云端额外请求头")
        timeoutPicker.addItems(withTitles: CloudEditorSettings.timeouts.map { "\(Int($0)) 秒" })
        timeoutPicker.selectItem(at: CloudEditorSettings.timeouts.firstIndex(of: settings.timeout) ?? 1)
        timeoutPicker.setAccessibilityLabel("快模型超时")
        for (box, on) in [(cleanup, settings.enabled), (translation, settings.translation), (meetings, settings.meetings), (tuning, settings.tuning)] {
            box.target = self; box.action = #selector(featuresChanged); box.state = on ? .on : .off
        }
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        testButton = app.button("测试连接", #selector(test)); testButton.target = self
        let save = app.button("保存", #selector(saveSettings)); save.target = self
        let form = VoiceAppearance.form([("协议", protocolPicker), ("API 地址", baseURL), ("快模型", model), ("强模型", strongModel),
                                         ("API Key", key), ("请求头", headers), ("快模型超时", timeoutPicker)])
        refresh()
        return app.card("云端模型（可选）", "默认全部在本机处理。填好服务后，按功能勾选要用云端的地方。", views: [
            form, app.row([save, testButton]), app.label("使用云端的功能", size: 13), cleanup, translation, meetings, tuning,
            app.label("夜间整理（画像与转写热词、夜间整理规则优化）在「常用词与学习」里开启。", size: 12, color: .secondaryLabelColor), status,
            app.label("口述整理和翻译发送原稿、输入框文字、应用名、窗口标题、网站域名和个人词库；屏幕上的可见文字和文字识别结果始终只留在本机。规则优化发送插入后被你改过的口述记录（原稿、整理结果、你改后的文字）。会议写作发送本地纪要和引文。音频从不上传。云端结果和本地结果经过同样的安全校验；API Key 与请求头存入 macOS 钥匙串。", size: 12, color: .secondaryLabelColor)])
    }

    func refresh() {
        let settings = CloudEditorSettings.load()
        if settings.baseURL.isEmpty || settings.model.isEmpty { status.stringValue = "尚未配置云端服务，全部功能使用本地模型。"; return }
        if !CloudEditorSettings.hasSecret(settings.baseURL) { status.stringValue = "缺少 API Key：请填写后保存。当前全部使用本地模型。"; return }
        if status.stringValue.isEmpty || status.stringValue.hasPrefix("当前") || status.stringValue.hasPrefix("尚未") || status.stringValue.hasPrefix("缺少") {
            status.stringValue = Self.summary(settings)
        }
    }

    static func summary(_ s: CloudEditorSettings) -> String {
        let fast = [s.enabled ? "口述整理" : nil, s.translation ? "翻译" : nil].compactMap { $0 }
        let strong = [s.meetings ? "会议写作" : nil, s.tuning ? "规则优化" : nil, NightlySettings.load().active ? "夜间整理" : nil].compactMap { $0 }
        if fast.isEmpty && strong.isEmpty { return "当前没有勾选任何功能，全部使用本地模型。" }
        return "当前" + [fast.isEmpty ? nil : "\(fast.joined(separator: "、"))用快模型 \(s.model)",
                       strong.isEmpty ? nil : "\(strong.joined(separator: "、"))用强模型 \(s.strongName)"].compactMap { $0 }.joined(separator: "；") + "。"
    }

    private func readForm() throws -> CloudEditorSettings {
        var s = CloudEditorSettings.load()
        s.protocolName = CloudEditorSettings.protocols[max(0, protocolPicker.indexOfSelectedItem)].0
        s.baseURL = try CloudEditorSettings.validated(baseURL: baseURL.stringValue)
        s.model = model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.model.isEmpty else { throw VoiceError.message("请输入快模型的名称") }
        s.strongModel = strongModel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        s.timeout = CloudEditorSettings.timeouts[max(0, timeoutPicker.indexOfSelectedItem)]
        readFeatures(into: &s)
        return s
    }

    private func readFeatures(into s: inout CloudEditorSettings) {
        s.enabled = cleanup.state == .on; s.translation = translation.state == .on; s.meetings = meetings.state == .on
        s.tuning = tuning.state == .on
    }

    /// Key and headers typed into the form; nil keeps what the Keychain has.
    private func typedCredentials() throws -> (key: String?, headers: [String: String]?) {
        let headerText = try CloudEditorSettings.validated(headers: headers.stringValue)
        let parsed = headerText.isEmpty ? nil : (try? JSONSerialization.jsonObject(with: Data(headerText.utf8)) as? [String: String]) ?? nil
        return (key.stringValue.isEmpty ? nil : key.stringValue, parsed)
    }

    /// Store what was typed (if anything), then run `next` with the result.
    private func storeTyped(for s: CloudEditorSettings, next: @escaping (Error?) -> Void) throws {
        let typed = try typedCredentials()
        guard typed.key != nil || typed.headers != nil else {
            next(CloudEditorSettings.hasSecret(s.baseURL) ? nil : VoiceError.message("请输入 API Key 后保存")); return
        }
        key.stringValue = ""; headers.stringValue = ""
        CloudCredentialStore.update(s.baseURL, key: typed.key, headers: typed.headers, completion: next)
    }

    @objc func saveSettings() {
        do {
            let s = try readForm()
            status.stringValue = "正在保存…"
            try storeTyped(for: s) { [weak self] error in
                guard let self = self else { return }
                if let error = error { self.status.stringValue = error.localizedDescription; return }
                s.save()
                self.status.stringValue = "已保存。" + Self.summary(s)
                self.app.cloudSettingsChanged()
            }
        } catch { status.stringValue = error.localizedDescription }
    }

    /// A feature switch applies at once; the service fields still need 保存.
    @objc func featuresChanged() {
        var s = CloudEditorSettings.load(); readFeatures(into: &s); s.save()
        status.stringValue = Self.summary(s)
        if s.readsKeyAtLaunch && s.serviceReady { CloudCredentialStore.prefetch(s.baseURL) }
        app.cloudSettingsChanged()
    }

    /// Tests the fast model, then the strong one when it is a different model.
    @objc func test() {
        do {
            let s = try readForm()
            guard app.worker.ready else { throw VoiceError.message("本地模型就绪后才能测试连接") }
            status.stringValue = "正在测试…（如果 macOS 询问钥匙串访问，请选择“始终允许”）"; testButton.isEnabled = false
            try storeTyped(for: s) { [weak self] error in
                guard let self = self else { return }
                if let error = error { self.status.stringValue = error.localizedDescription; self.testButton.isEnabled = true; return }
                CloudCredentialStore.prefetch(s.baseURL) { credentials in
                    guard let credentials = credentials else {
                        self.status.stringValue = "无法从钥匙串读取 API Key：请重新输入，或在系统询问时选择“始终允许”。"; self.testButton.isEnabled = true; return
                    }
                    var models = [(s.model, s.payload(with: credentials))]
                    if s.strongName != s.model { var strong = s.payload(with: credentials, strong: true); strong["timeout_seconds"] = 20; models.append((s.strongName, strong)) }
                    self.probe(models, results: [])
                }
            }
        } catch { status.stringValue = error.localizedDescription; testButton.isEnabled = true }
    }

    private func probe(_ models: [(String, [String: Any])], results: [String]) {
        guard let (name, payload) = models.first else {
            testButton.isEnabled = true; status.stringValue = results.joined(separator: "；") + "。保存后生效。"; return
        }
        app.worker.request("cloud_test", ["cloud": payload]) { [weak self] result in
            guard let self = self else { return }
            let line: String
            switch result {
            case .success(let value): line = String(format: "%@ 正常 · %.1f 秒", name, value["seconds"] as? Double ?? 0)
            case .failure(let error): line = "\(name) 失败：\(CloudEditorSettings.describe(fallback: error.localizedDescription))"
            }
            self.probe(Array(models.dropFirst()), results: results + [line])
        }
    }
}
