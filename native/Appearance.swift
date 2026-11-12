import AppKit

/// Shared native surfaces for the settings cards and the recording panel.
enum VoiceAppearance {
    static func card() -> NSBox {
        let box = NSBox(); box.boxType = .custom; box.titlePosition = .noTitle
        box.cornerRadius = 10; box.borderColor = .separatorColor; box.borderWidth = 0.5
        box.fillColor = .controlBackgroundColor
        return box
    }
    static func form(_ entries: [(String, NSView)]) -> NSGridView {
        let grid = NSGridView(views:entries.map { [NSTextField(labelWithString:$0.0),$0.1] })
        grid.rowSpacing = 12; grid.columnSpacing = 14
        grid.column(at:0).width = 78; grid.column(at:0).xPlacement = .trailing
        grid.column(at:1).xPlacement = .fill
        for index in entries.indices { grid.row(at:index).yPlacement = .center }
        return grid
    }
}

final class SidebarButton: NSButton {
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        if state == .on {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:7,yRadius:7).fill()
        }
        super.draw(dirtyRect)
    }
}

/// A collapsed group of settings behind a disclosure row. Everyday settings stay
/// visible; this holds the ones most people never need. The open/closed state
/// is remembered under `key`.
final class DisclosureSection: NSStackView {
    private let content = NSStackView()
    private let toggle = NSButton()
    private let key: String
    init(title: String, subtitle: String? = nil, key: String, views: [NSView], spacing: CGFloat = 18) {
        self.key = key
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; self.spacing = 10
        toggle.bezelStyle = .disclosure; toggle.setButtonType(.pushOnPushOff); toggle.title = ""
        toggle.target = self; toggle.action = #selector(changed); toggle.setAccessibilityLabel("展开或收起\(title)")
        let name = NSButton(title: title, target: self, action: #selector(flip))
        name.isBordered = false; name.font = .systemFont(ofSize: 14, weight: .medium)
        var header: [NSView] = [toggle, name]
        if let subtitle = subtitle {
            let hint = NSTextField(labelWithString: subtitle); hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor
            header.append(hint)
        }
        let row = NSStackView(views: header); row.orientation = .horizontal; row.spacing = 6; row.alignment = .centerY
        addArrangedSubview(row)
        content.orientation = .vertical; content.alignment = .leading; content.spacing = spacing
        for view in views {
            content.addArrangedSubview(view)
            if view is NSBox || view is NSGridView || view is NSTextField { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        }
        addArrangedSubview(content)
        content.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        toggle.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
        content.isHidden = toggle.state == .off
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var expanded: Bool {
        get { toggle.state == .on }
        set { toggle.state = newValue ? .on : .off; changed() }
    }
    /// Open without remembering it, e.g. while a required permission is missing.
    func reveal() { toggle.state = .on; content.isHidden = false }
    @objc private func flip() { expanded = !expanded }
    @objc private func changed() {
        content.isHidden = toggle.state == .off
        UserDefaults.standard.set(toggle.state == .on, forKey: key)
    }
}
