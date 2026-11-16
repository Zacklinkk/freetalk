import AppKit

/// Translation input (dictate, insert a translation), window text recognition
/// and rich-text paste: the settings and the pieces of the dictation flow.
extension AppDelegate {
    static let translationTargets: [(code: String, title: String)] = [
        ("auto", "自动：中文译成英文，其他译成中文"), ("en", "English"), ("zh", "简体中文"), ("ja", "日本語"),
        ("ko", "한국어"), ("fr", "Français"), ("de", "Deutsch"), ("es", "Español")]

    var translationShortcutEnabled: Bool { UserDefaults.standard.object(forKey: "translationShortcutEnabled") as? Bool ?? true }
    var translationTarget: String { UserDefaults.standard.string(forKey: "translationTarget") ?? "auto" }
    var translationTargetTitle: String {
        Self.translationTargets.first { $0.code == translationTarget }.map { $0.code == "auto" ? "自动语言" : $0.title } ?? "自动语言"
    }

    /// The saved translation key, the default, or none when it is off or now collides.
    func loadTranslationBinding() {
        guard translationShortcutEnabled else { hotkey.update(translation: nil); return }
        let saved = HotkeyBinding.load("translationBindingV1") ?? .defaultTranslation
        let usable = [saved, .defaultTranslation].first {
            HotkeyValidation.translationProblem(for: $0, dictation: hotkey.binding, meeting: hotkey.meetingBinding) == nil
        }
        hotkey.update(translation: usable)
    }

    func makeTranslationControls() -> NSView {
        translationShortcutButton = NSButton(title: hotkey.translationBinding?.display ?? HotkeyBinding.defaultTranslation.display,
                                             target: self, action: #selector(recordTranslationShortcut))
        translationShortcutButton.bezelStyle = .rounded
        translationEnabledButton = NSButton(checkboxWithTitle: "启用", target: self, action: #selector(translationOptionsChanged))
        translationEnabledButton.state = translationShortcutEnabled ? .on : .off
        translationTargetPicker = NSPopUpButton()
        translationTargetPicker.addItems(withTitles: Self.translationTargets.map(\.title))
        translationTargetPicker.selectItem(at: Self.translationTargets.firstIndex { $0.code == translationTarget } ?? 0)
        translationTargetPicker.target = self; translationTargetPicker.action = #selector(translationOptionsChanged)
        translationTargetPicker.setAccessibilityLabel("翻译目标语言")
        return row([label("翻译输入", size: 12), translationShortcutButton, translationTargetPicker, translationEnabledButton])
    }

    func refreshTranslationLabel() {
        guard translationShortcutButton != nil, !hotkeyRecorder.isRecording else { return }
        translationShortcutButton.title = hotkey.translationBinding?.display ?? HotkeyBinding.defaultTranslation.display
        translationShortcutButton.isEnabled = translationShortcutEnabled
    }

    @objc func translationOptionsChanged() {
        UserDefaults.standard.set(translationEnabledButton.state == .on, forKey: "translationShortcutEnabled")
        UserDefaults.standard.set(Self.translationTargets[max(0, translationTargetPicker.indexOfSelectedItem)].code, forKey: "translationTarget")
        loadTranslationBinding(); refreshTranslationLabel()
        shortcutTestLabel?.stringValue = translationShortcutEnabled
            ? "\(hotkey.translationBinding?.display ?? "") 开始翻译输入：口述后插入\(translationTargetTitle == "自动语言" ? "译文" : translationTargetTitle + "译文")。"
            : "已关闭翻译快捷键"
    }

    @objc func recordTranslationShortcut() {
        hotkeyTester.stop(); cancelShortcutRecording()
        shortcutTestLabel?.stringValue = "录制中…"
        translationShortcutButton.title = "请按下快捷键…"
        hotkey.suspended = true
        hotkeyRecorder.begin(validate: { [weak self] binding in
            guard let self = self else { return nil }
            return HotkeyValidation.translationProblem(for: binding, dictation: self.hotkey.binding, meeting: self.hotkey.meetingBinding)
        }, onStatus: { [weak self] text in
            self?.shortcutTestLabel?.stringValue = text
        }, onFinish: { [weak self] result in
            guard let self = self else { return }
            self.hotkey.suspended = false
            switch result {
            case .recorded(let binding):
                binding.save("translationBindingV1")
                UserDefaults.standard.set(true, forKey: "translationShortcutEnabled"); self.translationEnabledButton.state = .on
                self.loadTranslationBinding()
                let warning = HotkeyValidation.conflictWarning(for: binding).map { "。\($0)" } ?? ""
                self.shortcutTestLabel?.stringValue = "已保存：翻译键 \(binding.display)\(warning)"
                self.updateHotkey()
            case .cancelled: self.shortcutTestLabel?.stringValue = "已取消录制"
            }
            self.refreshTranslationLabel()
        })
    }

    /// Either key ends a recording; the mode is the one it started with.
    func translateToggle() {
        if phase == .recording || phase == .preparing { toggle(); return }
        startOrStop(translate: true)
    }

    /// What the worker needs to translate this dictation.
    func translationRequest() -> [String: Any] {
        var request: [String: Any] = ["mode": "translate", "target_language": translationTarget]
        let cloud = CloudEditorSettings.load()
        if cloud.translation && cloud.serviceReady {
            if let credentials = CloudCredentialStore.cached(cloud.baseURL) { request["translation_cloud"] = cloud.payload(with: credentials) }
            else { CloudCredentialStore.prefetch(cloud.baseURL) }
        }
        return request
    }

    /// One line for the result details: what was translated, or why not.
    static func translationSummary(_ meta: [String: Any]?) -> String? {
        guard let meta = meta else { return nil }
        let name = translationTargets.first { $0.code == meta["target"] as? String }?.title ?? "目标语言"
        if meta["status"] as? String == "translated" {
            return "已翻译为 \(name)" + (meta["engine"] as? String == "cloud" ? "（云端快模型）" : "（本地模型）")
        }
        return "翻译未完成，已输入整理后的原文"
    }

    // MARK: Window text recognition

    var windowRecognitionEnabled: Bool {
        UserDefaults.standard.bool(forKey: "windowOCREnabled") && UserDefaults.standard.bool(forKey: "windowContextEnabled")
    }

    @objc func windowRecognitionChanged(_ sender: NSButton) {
        let on = sender.state == .on
        UserDefaults.standard.set(on, forKey: "windowOCREnabled")
        guard on else { return }
        // Recognition supplements visible text; it needs that switch too.
        UserDefaults.standard.set(true, forKey: "windowContextEnabled"); nearbyButton?.state = .on
        if !WindowText.permitted && !WindowText.requestPermission() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            setStatus("请在系统设置的“屏幕录制”里允许 freetalk；授权后重新打开 freetalk 生效。")
        }
        if WindowText.permitted { WindowText.warmUp() }
    }

    /// Recognize the target window's text when Accessibility gave little, and
    /// hand it to the worker as more visible text for this dictation.
    func recognizeWindowText(token: UUID, nearby: String) {
        guard windowRecognitionEnabled, contextButton.state == .on, let target = target, nearby.count < WindowText.enough else { return }
        WindowText.recognize(pid: target.pid, bundle: target.bundle, title: target.identity.windowTitle, anchor: target.anchor) { [weak self] text in
            guard let self = self, self.session == token, self.phase == .preparing || self.phase == .recording, !text.isEmpty else { return }
            self.worker.request("context", ["nearby": text])
        }
    }

    // MARK: Rich text

    @objc func richTextChanged(_ sender: NSButton) { UserDefaults.standard.set(sender.state == .on, forKey: "richTextPaste") }

    /// HTML for structured text in apps that paste rich text; never for terminals or code editors.
    func richHTML(_ text: String) -> String? {
        guard UserDefaults.standard.object(forKey: "richTextPaste") as? Bool ?? true, let target = target,
              !["terminal", "development"].contains(InputSnapshot.scene(for: target.bundle)) else { return nil }
        return RichText.html(text)
    }
}
