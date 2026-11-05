import AppKit

/// Shared by the settings page and the permission-free HUD preview.
final class RecordingLimitView: NSStackView {
    private let picker = NSPopUpButton()
    private let custom = NSTextField(string: "")
    private let apply = NSButton(title: "应用", target: nil, action: nil)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let customRow = NSStackView()
    private let defaults: UserDefaults
    private let legacy: () -> Any?
    private var customSelected = false
    var isEnabled = true {
        didSet { picker.isEnabled = isEnabled; custom.isEnabled = isEnabled; apply.isEnabled = isEnabled }
    }

    init(defaults: UserDefaults = .standard, legacy: @escaping () -> Any?) {
        self.defaults = defaults; self.legacy = legacy
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 8
        let title = NSTextField(labelWithString: "自动结束")
        picker.addItems(withTitles: DictationLimit.presets.map { DictationLimit.title(Double($0)) + ($0 == 180 ? "（推荐）" : "") } + ["自定义…"])
        picker.target = self; picker.action = #selector(selectionChanged)
        picker.setAccessibilityLabel("单次语音输入时长上限")
        let heading = NSStackView(views: [title, picker]); heading.spacing = 10; heading.alignment = .centerY
        addArrangedSubview(heading)
        custom.placeholderString = "30–600"; custom.alignment = .right
        custom.setAccessibilityLabel("自定义录音时长（秒）")
        custom.widthAnchor.constraint(equalToConstant: 70).isActive = true
        custom.target = self; custom.action = #selector(applyCustom)
        apply.target = self; apply.action = #selector(applyCustom); apply.bezelStyle = .rounded
        customRow.orientation = .horizontal; customRow.alignment = .centerY; customRow.spacing = 8
        for view in [custom, NSTextField(labelWithString: "秒"), apply] { customRow.addArrangedSubview(view) }
        addArrangedSubview(customRow)
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        addArrangedSubview(hint); hint.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var seconds: TimeInterval { DictationLimit.effective(preference: defaults.object(forKey: DictationLimit.preferenceKey), legacy: legacy()) }
    func refresh() {
        let value = seconds
        if let index = DictationLimit.presets.firstIndex(of: Int(value)) {
            picker.selectItem(at: index); customSelected = false
        } else { picker.selectItem(at: DictationLimit.presets.count); customSelected = true }
        custom.stringValue = String(Int(value)); customRow.isHidden = !customSelected
        showHint()
    }
    private func showHint() {
        hint.textColor = .secondaryLabelColor
        hint.stringValue = "当前上限 \(DictationLimit.title(seconds)) · 最后 10 秒提醒\n可设 30–600 秒；日常推荐 3 分钟，更长内容可用会议资料。"
    }
    @objc private func selectionChanged() {
        guard isEnabled else { return }
        customSelected = picker.indexOfSelectedItem == DictationLimit.presets.count
        customRow.isHidden = !customSelected
        if customSelected {
            custom.stringValue = String(Int(seconds)); window?.makeFirstResponder(custom)
        } else if DictationLimit.presets.indices.contains(picker.indexOfSelectedItem) {
            defaults.set(DictationLimit.presets[picker.indexOfSelectedItem], forKey: DictationLimit.preferenceKey)
        }
        showHint()
    }
    @objc private func applyCustom() {
        guard isEnabled else { return }
        let text = custom.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(text), DictationLimit.range.contains(value) else {
            hint.stringValue = "请输入 30–600 之间的整数秒；当前上限仍为 \(DictationLimit.title(seconds))。"
            hint.textColor = .systemRed; return
        }
        defaults.set(value, forKey: DictationLimit.preferenceKey)
        window?.makeFirstResponder(picker); showHint()
    }
}
