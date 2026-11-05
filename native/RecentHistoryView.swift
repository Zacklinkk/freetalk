import AppKit

/// A compact, recycled list of the existing history. Browsing never changes the latest result.
final class RecentHistoryView: NSStackView, NSTableViewDataSource, NSTableViewDelegate {
    private let store: VoiceHistoryStore
    private let table = NSTableView(), scroll = NSScrollView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var rows: [VoiceHistoryEntry] = []
    var onOpen: ((String) -> Void)?

    init(store: VoiceHistoryStore) {
        self.store = store
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 10
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.setAccessibilityLabel("历史记录数量"); addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.resizingMask = .autoresizingMask; table.addTableColumn(column)
        table.headerView = nil; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.style = .plain; table.rowHeight = 88; table.intercellSpacing = NSSize(width: 0, height: 4)
        table.backgroundColor = .clear; table.selectionHighlightStyle = .regular
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(openSelected)
        table.setAccessibilityLabel("最近转写历史列表")
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.borderType = .noBorder; scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        addArrangedSubview(scroll)
        NSLayoutConstraint.activate([scroll.widthAnchor.constraint(equalTo: widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160)])
        setContentHuggingPriority(.defaultLow, for: .vertical)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() {
        let selectedID = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
        let origin = scroll.contentView.bounds.origin
        let firstVisible = table.rows(in: scroll.contentView.bounds).location
        let anchorID = rows.indices.contains(firstVisible) ? rows[firstVisible].id : nil
        let offset = rows.indices.contains(firstVisible) ? origin.y - table.rect(ofRow: firstVisible).minY : 0
        rows = store.entries
        table.reloadData()
        if let selectedID = selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        table.layoutSubtreeIfNeeded()
        var y = origin.y
        if origin.y > 0, let anchorID = anchorID, let index = rows.firstIndex(where: { $0.id == anchorID }) {
            y = table.rect(ofRow: index).minY + offset
        }
        y = min(max(0, y), max(0, table.bounds.height - scroll.contentView.bounds.height))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
        status.stringValue = store.error ?? (rows.isEmpty
            ? "还没有转写记录。完成一次语音输入后，会显示在这里。"
            : "\(rows.count) 条 · 最新在前 · 最多保留 \(VoiceHistoryStore.limit) 条，自动删除最旧记录")
        status.textColor = store.error == nil ? .secondaryLabelColor : .systemRed
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("history-preview")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? HistoryPreviewCell ?? HistoryPreviewCell()
        cell.identifier = identifier
        cell.configure(rows[row])
        cell.onOpen = { [weak self] id in self?.onOpen?(id) }
        return cell
    }
    @objc private func openSelected() {
        guard rows.indices.contains(table.clickedRow) else { return }
        onOpen?(rows[table.clickedRow].id)
    }
}

private final class HistoryPreviewCell: NSTableCellView {
    private let metadata = NSTextField(labelWithString: "")
    private let preview = NSTextField(wrappingLabelWithString: "")
    private let copy = NSButton()
    private var entry: VoiceHistoryEntry?
    var onOpen: ((String) -> Void)?
    private static let date: DateFormatter = {
        let value = DateFormatter(); value.dateFormat = "MM-dd HH:mm:ss"; return value
    }()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        metadata.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        metadata.textColor = .secondaryLabelColor; metadata.lineBreakMode = .byTruncatingTail
        preview.font = .systemFont(ofSize: 13); preview.maximumNumberOfLines = 2
        preview.lineBreakMode = .byTruncatingTail; preview.setAccessibilityLabel("转写摘要")
        preview.cell?.wraps = true; preview.cell?.isScrollable = false; preview.cell?.usesSingleLineMode = false
        copy.title = "复制"; copy.target = self; copy.action = #selector(copyEntry); copy.bezelStyle = .inline
        let open = NSButton(title: "查看", target: self, action: #selector(openEntry)); open.bezelStyle = .inline
        let actions = NSStackView(views: [open, copy]); actions.orientation = .horizontal; actions.spacing = 8
        for view in [metadata, preview, actions] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            metadata.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), metadata.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            metadata.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -12),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), actions.centerYAnchor.constraint(equalTo: metadata.centerYAnchor),
            preview.leadingAnchor.constraint(equalTo: metadata.leadingAnchor), preview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            preview.topAnchor.constraint(equalTo: metadata.bottomAnchor, constant: 8), preview.heightAnchor.constraint(equalToConstant: 36),
            preview.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10)
        ])
        metadata.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ entry: VoiceHistoryEntry) {
        self.entry = entry; copy.title = "复制"
        metadata.stringValue = [Self.date.string(from: entry.createdAt), entry.targetApp].filter { !$0.isEmpty }.joined(separator: " · ")
        preview.stringValue = entry.text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        copy.setAccessibilityLabel("复制 \(Self.date.string(from: entry.createdAt)) 的转写")
    }
    @objc private func openEntry() { if let entry = entry { onOpen?(entry.id) } }
    @objc private func copyEntry() {
        guard let entry = entry else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.text, forType: .string)
        copy.title = "已复制"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.entry?.id == entry.id { self?.copy.title = "复制" }
        }
    }
}
