import AppKit

struct VoiceHistoryEntry: Codable, Identifiable {
    var id: String
    var createdAt: Date
    var text: String
    var raw: String
    var targetApp: String
    var insertionStatus: String
    var audioSeconds: Double
    var stopToTextSeconds: Double
    var cleanupSeconds: Double
    var cleanupStatus: String
    var modelUsed: Bool
    var cleanupRoute: String? = nil
    var cleanupReason: String? = nil
    var appliedEdits: Int? = nil
    var rejectedEdits: Int? = nil
    /// How a paste was confirmed (exact/normalized/contains_insert) or why not
    /// (no_value/unchanged/different/cleared). Never contains text.
    var insertionCheck: String? = nil
}

final class VoiceHistoryStore {
    static let limit = 500
    private(set) var entries: [VoiceHistoryEntry] = []
    private(set) var error: String?
    private var writable = true
    private let file: URL
    init(directory: URL) {
        file = directory.appendingPathComponent("history.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: file.path) {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                entries = try decoder.decode([VoiceHistoryEntry].self, from: Data(contentsOf: file))
                if entries.count > Self.limit { entries = Array(entries.prefix(Self.limit)); persist() }
            } else {
                // Migrate the one record the previous version kept, without inventing history.
                let legacy = directory.appendingPathComponent("last-result.json")
                if let data = try? Data(contentsOf: legacy), let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let text = item["text"] as? String, !text.isEmpty {
                    entries = [VoiceHistoryEntry(id: UUID().uuidString,
                        createdAt: ISO8601DateFormatter().date(from: item["savedAt"] as? String ?? "") ?? Date(),
                        text: text, raw: item["raw"] as? String ?? text, targetApp: "旧版最近记录",
                        insertionStatus: "旧版未保存插入状态", audioSeconds: 0, stopToTextSeconds: 0,
                        cleanupSeconds: 0, cleanupStatus: "旧版未记录", modelUsed: false)]
                }
                persist()
            }
        } catch {
            writable = false
            self.error = "历史文件读取失败，已保留原文件：\(error.localizedDescription)"
        }
    }
    func upsert(_ entry: VoiceHistoryEntry) {
        guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry }
        else { entries.insert(entry, at: 0) }
        entries = Array(entries.prefix(Self.limit)); persist()
    }
    private func persist() {
        guard writable else { return }
        do {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try encoder.encode(entries).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            error = nil
        } catch { self.error = "历史保存失败：\(error.localizedDescription)" }
    }
}

final class HistoryWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let store: VoiceHistoryStore
    let window: NSWindow
    let table = NSTableView(), text = NSTextView(), search = NSSearchField(), info = NSTextField(wrappingLabelWithString: "")
    let mode = NSSegmentedControl(labels: ["整理结果", "原始转写"], trackingMode: .selectOne, target: nil, action: nil)
    private var rows: [VoiceHistoryEntry] = []
    init(store: VoiceHistoryStore) {
        self.store = store
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 580), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "freetalk · 转写历史（最多500条）"; window.isReleasedWhenClosed = false; window.center()
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -18), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -18)])
        search.placeholderString = "搜索原稿或整理结果"; search.setAccessibilityLabel("搜索转写历史"); search.target = self; search.action = #selector(refresh)
        stack.addArrangedSubview(search); search.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for (key, title, width) in [("time","时间",145.0),("app","目标应用",110.0),("text","内容",410.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self; table.rowHeight = 28; table.setAccessibilityLabel("转写历史列表")
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true; list.borderType = .bezelBorder
        stack.addArrangedSubview(list); list.heightAnchor.constraint(equalToConstant: 220).isActive = true; list.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        mode.selectedSegment = 0; mode.target = self; mode.action = #selector(selectionChanged)
        let copy = NSButton(title: "复制所选记录", target: self, action: #selector(copySelected)); copy.bezelStyle = .rounded
        let actions = NSStackView(views: [mode,copy]); actions.orientation = .horizontal; actions.spacing = 12; stack.addArrangedSubview(actions)
        info.font = .systemFont(ofSize: 12); info.textColor = .secondaryLabelColor; stack.addArrangedSubview(info)
        text.isEditable = false; text.isSelectable = true; text.font = .systemFont(ofSize: 14); text.textContainerInset = NSSize(width: 8, height: 8)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true; text.setAccessibilityLabel("历史记录内容")
        let detail = NSScrollView(); detail.documentView = text; detail.hasVerticalScroller = true; detail.borderType = .bezelBorder
        stack.addArrangedSubview(detail); detail.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true; detail.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    func show(entryID: String? = nil) {
        if entryID != nil { search.stringValue = ""; mode.selectedSegment = 0 }
        reloadRows(selecting: entryID); window.makeKeyAndOrderFront(nil)
        if entryID != nil, table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) }
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func refresh() { reloadRows(selecting: nil) }
    private func reloadRows(selecting entryID: String?) {
        let selected = entryID ?? (rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil)
        let q = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        rows = store.entries.filter { q.isEmpty || $0.text.localizedCaseInsensitiveContains(q) || $0.raw.localizedCaseInsensitiveContains(q) }
        table.reloadData()
        if !rows.isEmpty {
            let index = rows.firstIndex(where: { $0.id == selected }) ?? 0
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        selectionChanged()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]; let content: String
        switch tableColumn?.identifier.rawValue {
        case "time": let formatter = DateFormatter(); formatter.dateFormat = "MM-dd HH:mm:ss"; content = formatter.string(from: item.createdAt)
        case "app": content = item.targetApp
        default: content = item.text.replacingOccurrences(of: "\n", with: " ")
        }
        let label = NSTextField(labelWithString: content); label.lineBreakMode = .byTruncatingTail; return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { selectionChanged() }
    @objc func selectionChanged() {
        guard rows.indices.contains(table.selectedRow) else { text.string = ""; info.stringValue = store.error ?? "没有匹配的记录 · 最多保留500条，自动淘汰最旧记录"; return }
        let entry = rows[table.selectedRow]
        text.string = mode.selectedSegment == 1 ? entry.raw : entry.text
        info.stringValue = "\(store.entries.count)/500条 · \(entry.cleanupStatus) · \(entry.insertionStatus)\n" + String(format: "录音 %.1f秒 · 停止到文字 %.2f秒 · 整理 %.2f秒", entry.audioSeconds, entry.stopToTextSeconds, entry.cleanupSeconds)
        if entry.modelUsed, let count=entry.appliedEdits { info.stringValue += " · 词句修改 \(count) 处" }
        if let count=entry.rejectedEdits, count>0 { info.stringValue += " · 保守拦截 \(count) 处" }
        info.toolTip = [entry.cleanupRoute,entry.cleanupReason].compactMap { $0 }.joined(separator:" · ")
        if let error = store.error { info.stringValue += "\n" + error }
    }
    @objc func copySelected() {
        guard rows.indices.contains(table.selectedRow) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text.string, forType: .string)
    }
}
