import AppKit

/// Settings card and actions for the optional cloud cleanup model.
final class CloudEditorPanel: NSObject {
    unowned let app: AppDelegate
    let enable = NSButton(checkboxWithTitle: "用云端模型整理（失败时自动改用本地模型）", target: nil, action: nil)
    let protocolPicker = NSPopUpButton()
    let baseURL = NSTextField(), model = NSTextField(), key = NSSecureTextField(), headers = NSTextField()
    let timeoutPicker = NSPopUpButton()
    let status = NSTextField(wrappingLabelWithString: "")
    private var testButton: NSButton!

    init(app: AppDelegate) { self.app = app; super.init() }

    func makeCard() -> NSView {
        let settings = CloudEditorSettings.load()
        enable.target = self; enable.action = #selector(enableChanged); enable.state = settings.enabled ? .on : .off
        protocolPicker.addItems(withTitles: CloudEditorSettings.protocols.map(\.1))
        protocolPicker.selectItem(at: CloudEditorSettings.protocols.firstIndex { $0.0 == settings.protocolName } ?? 0)
        protocolPicker.setAccessibilityLabel("云端接口协议")
        baseURL.placeholderString = "https://你的服务/v1"; baseURL.stringValue = settings.baseURL; baseURL.setAccessibilityLabel("云端整理 API 地址")
        model.placeholderString = "服务提供的模型名称，建议选响应快的小模型"; model.stringValue = settings.model; model.setAccessibilityLabel("云端整理模型名称")
        key.placeholderString = "API Key · 留空保留钥匙串中的密钥"; key.setAccessibilityLabel("云端整理 API Key")
        headers.placeholderString = "可选 · 网关要求的额外请求头，JSON 对象"; headers.setAccessibilityLabel("云端整理额外请求头")
        timeoutPicker.addItems(withTitles: CloudEditorSettings.timeouts.map { "\(Int($0)) 秒" })
        timeoutPicker.selectItem(at: CloudEditorSettings.timeouts.firstIndex(of: settings.timeout) ?? 1)
        timeoutPicker.setAccessibilityLabel("云端整理超时")
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        testButton = app.button("测试连接", #selector(test)); testButton.target = self
        let save = app.button("保存", #selector(saveSettings)); save.target = self
        let form = VoiceAppearance.form([("协议", protocolPicker), ("API 地址", baseURL), ("模型", model), ("API Key", key), ("请求头", headers), ("超时", timeoutPicker)])
        refresh()
        return app.card("云端整理（可选）", "默认在本机整理。开启后，先把原稿、输入框文字、应用名和个人词库发送到你指定的服务；当前窗口可见文字始终只留在本机。", views: [
            enable, form, app.row([save, testButton]), status,
            app.label("云端超时、拒绝或返回无法使用的结果时，本次自动改用本地模型，并在浮窗中提示。云端结果和本地结果经过同样的安全校验。API Key 与请求头存入 macOS 钥匙串。", size: 12, color: .secondaryLabelColor)])
    }

    func refresh() {
        let settings = CloudEditorSettings.load()
        let ready = settings.payload() != nil
        if settings.enabled && !ready { status.stringValue = "已开启但配置不完整：请填写地址、模型和 API Key 后保存。当前使用本地模型。" }
        else if !settings.enabled { status.stringValue = "当前使用本地模型。" }
        else if status.stringValue.isEmpty || status.stringValue.hasPrefix("当前") || status.stringValue.hasPrefix("已开启") {
            status.stringValue = "当前使用云端模型：\(settings.model)"
        }
    }

    private func readForm() throws -> CloudEditorSettings {
        var s = CloudEditorSettings.load()
        s.protocolName = CloudEditorSettings.protocols[max(0, protocolPicker.indexOfSelectedItem)].0
        s.baseURL = try CloudEditorSettings.validated(baseURL: baseURL.stringValue)
        s.model = model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.model.isEmpty else { throw VoiceError.message("请输入服务提供的模型名称") }
        s.timeout = CloudEditorSettings.timeouts[max(0, timeoutPicker.indexOfSelectedItem)]
        return s
    }

    @objc func saveSettings() {
        do {
            var s = try readForm()
            let headerText = try CloudEditorSettings.validated(headers: headers.stringValue)
            if !key.stringValue.isEmpty { try CloudEditorSettings.setSecret(key.stringValue, account: s.baseURL); key.stringValue = "" }
            guard !(CloudEditorSettings.secret(s.baseURL) ?? "").isEmpty else { throw VoiceError.message("请输入 API Key 后保存") }
            if !headers.stringValue.isEmpty { try CloudEditorSettings.setSecret(headerText, account: s.baseURL + "#headers"); headers.stringValue = "" }
            s.enabled = enable.state == .on
            s.save()
            status.stringValue = s.enabled ? "已保存，下次录音使用云端模型：\(s.model)" : "已保存。勾选上方开关后启用。"
        } catch { status.stringValue = error.localizedDescription }
    }

    @objc func enableChanged() {
        var s = CloudEditorSettings.load(); s.enabled = enable.state == .on; s.save()
        status.stringValue = ""; refresh()
    }

    @objc func test() {
        do {
            var s = try readForm(); s.enabled = true
            if !key.stringValue.isEmpty { try CloudEditorSettings.setSecret(key.stringValue, account: s.baseURL); key.stringValue = "" }
            if !headers.stringValue.isEmpty {
                try CloudEditorSettings.setSecret(try CloudEditorSettings.validated(headers: headers.stringValue), account: s.baseURL + "#headers")
                headers.stringValue = ""
            }
            guard let payload = s.payload() else { throw VoiceError.message("请输入 API Key 后测试") }
            guard app.worker.ready else { throw VoiceError.message("本地模型就绪后才能测试连接") }
            status.stringValue = "正在测试…"; testButton.isEnabled = false
            app.worker.request("cloud_test", ["cloud": payload]) { [weak self] result in
                guard let self = self else { return }
                self.testButton.isEnabled = true
                switch result {
                case .success(let value): self.status.stringValue = String(format: "连接正常 · %.1f 秒往返。保存后生效。", value["seconds"] as? Double ?? 0)
                case .failure(let error): self.status.stringValue = "连接失败：\(CloudEditorSettings.describe(fallback: error.localizedDescription))"
                }
            }
        } catch { status.stringValue = error.localizedDescription; testButton.isEnabled = true }
    }
}
