import AppKit
import ApplicationServices
import Carbon

struct OptionTapState {
    private var began: TimeInterval?
    private var chord = false
    mutating func keyDown() { if began != nil { chord = true } }
    mutating func flags(code: Int, rightDown: Bool, otherModifiers: Bool, now: TimeInterval) -> Bool {
        if code != 61 { if began != nil { chord = true }; return false }
        if rightDown { began = now; chord = otherModifiers; return false }
        let valid = began.map { now - $0 <= 0.45 && now >= $0 } ?? false
        let fire = valid && !chord && !otherModifiers
        began = nil; chord = false; return fire
    }
}

final class GlobalHotkey {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var state = OptionTapState()
    var onToggle: (() -> Void)?
    var onEscape: (() -> Void)?
    var active: Bool { tap != nil }
    func start() {
        stop()
        // Check, do not prompt implicitly at launch.
        guard CGPreflightListenEventAccess() else { return }
        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue) | (CGEventMask(1) << CGEventType.keyDown.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: { _, type, event, pointer in
                guard let pointer = pointer else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<GlobalHotkey>.fromOpaque(pointer).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    owner.state = OptionTapState()
                    return Unmanaged.passUnretained(event)
                }
                let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
                if type == .keyDown {
                    owner.state.keyDown()
                    if code == 53 { DispatchQueue.main.async { owner.onEscape?() } }
                } else if type == .flagsChanged {
                    let others = !event.flags.intersection([.maskCommand,.maskControl,.maskShift]).isEmpty
                    let rightDown = event.flags.rawValue & 0x40 != 0 // NX_DEVICERALTKEYMASK
                    if owner.state.flags(code: code, rightDown: rightDown, otherModifiers: others, now: ProcessInfo.processInfo.systemUptime) {
                        DispatchQueue.main.async { owner.onToggle?() }
                    }
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap = tap {
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
    func stop() {
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap = tap { CFMachPortInvalidate(tap) }
        source = nil; tap = nil; state = OptionTapState()
    }
    deinit { stop() }
}

func axAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func focusedElement(_ pid: pid_t) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.2)
    guard let value = axAttribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    let element = value as! AXUIElement
    AXUIElementSetMessagingTimeout(element, 0.2)
    return element
}

func selection(_ element: AXUIElement) -> CFRange? {
    guard let object = axAttribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(object) == AXValueGetTypeID() else { return nil }
    var range = CFRange()
    guard AXValueGetValue(object as! AXValue, .cfRange, &range) else { return nil }
    return range
}

func axRect(_ element: AXUIElement) -> CGRect? {
    guard let p = axAttribute(element, kAXPositionAttribute), let s = axAttribute(element, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero; var size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
    return CGRect(origin: point, size: size)
}

func axWindow(_ element: AXUIElement) -> AXUIElement? {
    guard let value = axAttribute(element, kAXWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

struct InputIdentity {
    let role: String, identifier: String, label: String, path: [Int], windowTitle: String, document: String
    let bounds: CGRect?
    // A re-created web node needs corroborating identity, not merely equal text.
    func matchesReplacement(_ other: InputIdentity) -> Bool {
        guard !path.isEmpty, path == other.path, role == other.role,
              windowTitle == other.windowTitle, document == other.document else { return false }
        if !identifier.isEmpty { return identifier == other.identifier }
        guard label == other.label, let a = bounds, let b = other.bounds else { return false }
        return abs(a.minX-b.minX) < 3 && abs(a.minY-b.minY) < 3 && abs(a.width-b.width) < 3 && abs(a.height-b.height) < 3
    }
    static func read(_ element: AXUIElement) -> InputIdentity {
        var path: [Int] = [], node = element, document = ""
        for _ in 0..<18 {
            if let url = axAttribute(node, kAXURLAttribute) { document = String(describing: url) }
            guard let p = axAttribute(node, kAXParentAttribute), CFGetTypeID(p) == AXUIElementGetTypeID() else { break }
            let parent = p as! AXUIElement
            guard let siblings = axAttribute(parent, kAXChildrenAttribute) as? [AXUIElement], siblings.count <= 1000,
                  let index = siblings.firstIndex(where: { CFEqual($0, node) }) else { path = []; break }
            path.append(index)
            if axAttribute(parent, kAXRoleAttribute) as? String == kAXWindowRole { break }
            node = parent
        }
        let win = axWindow(element)
        return InputIdentity(role: axAttribute(element, kAXRoleAttribute) as? String ?? "",
            identifier: axAttribute(element, kAXIdentifierAttribute) as? String ?? "",
            label: axAttribute(element, kAXDescriptionAttribute) as? String ?? "", path: path,
            windowTitle: win.flatMap { axAttribute($0, kAXTitleAttribute) as? String } ?? "",
            document: document, bounds: axRect(element))
    }
}

struct InputSnapshot {
    let pid: pid_t
    let name: String
    let element: AXUIElement
    let value: String
    let range: CFRange
    let identity: InputIdentity
    let window: AXUIElement?
    let anchor: CGRect?

    static func capture() throws -> InputSnapshot? {
        if IsSecureEventInputEnabled() { throw VoiceError.message("当前处于安全输入状态，请先离开密码框") }
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
            let element = focusedElement(app.processIdentifier) else { return nil }
        let subrole = axAttribute(element, kAXSubroleAttribute) as? String ?? ""
        if subrole.localizedCaseInsensitiveContains("secure") { throw VoiceError.message("密码框不接受语音输入") }
        let role = axAttribute(element, kAXRoleAttribute) as? String ?? ""
        guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
            let value = axAttribute(element, kAXValueAttribute) as? String,
            value.utf16.count <= 200_000, let range = selection(element),
            range.location >= 0, range.length >= 0, range.location + range.length <= value.utf16.count else { return nil }
        return InputSnapshot(pid: app.processIdentifier, name: app.localizedName ?? "当前应用", element: element,
            value: value, range: range, identity: InputIdentity.read(element), window: axWindow(element),
            anchor: caretRect(element, range) ?? axRect(element))
    }

    static func caretRect(_ element: AXUIElement, _ range: CFRange) -> CGRect? {
        var range = CFRange(location: range.location, length: 0)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var output: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &output) == .success,
              let output = output, CFGetTypeID(output) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(output as! AXValue, .cgRect, &rect), rect.height > 0, rect.origin.x.isFinite, rect.origin.y.isFinite else { return nil }
        return rect
    }

    func resolve(allowBackground: Bool = false) throws -> AXUIElement {
        guard !IsSecureEventInputEnabled() else { throw VoiceError.message("安全输入已开启") }
        guard AXIsProcessTrusted() else { throw VoiceError.message("辅助功能权限不可用") }
        if !allowBackground && NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { throw VoiceError.message("前台应用已切换") }
        guard let focused = focusedElement(pid) else { throw VoiceError.message("暂时无法读取目标输入框") }
        let subrole = axAttribute(focused, kAXSubroleAttribute) as? String ?? ""
        guard !subrole.localizedCaseInsensitiveContains("secure") else { throw VoiceError.message("目标变成了密码框") }
        if !CFEqual(focused, element) {
            guard let oldWindow = window, let newWindow = axWindow(focused), CFEqual(oldWindow, newWindow),
                identity.matchesReplacement(InputIdentity.read(focused)) else { throw VoiceError.message("焦点已离开录音开始时的输入框") }
        }
        guard let currentValue = axAttribute(focused, kAXValueAttribute) as? String else { throw VoiceError.message("目标输入框文字暂时不可读") }
        guard currentValue == value else { throw VoiceError.message("目标草稿在录音期间发生了变化") }
        guard let current = selection(focused) else { throw VoiceError.message("目标光标位置暂时不可读") }
        guard current.location == range.location && current.length == range.length else { throw VoiceError.message("光标或选区已移动") }
        return focused
    }
    func unchanged() -> Bool { (try? resolve()) != nil }
    func failureReason() -> String? { do { _ = try resolve(); return nil } catch { return error.localizedDescription } }
    func currentAnchor() -> CGRect? { guard let focused = try? resolve() else { return anchor }; return Self.caretRect(focused, range) ?? axRect(focused) ?? anchor }
    func context(enabled: Bool) -> [String: Any] {
        guard enabled else { return [:] }
        let text = value as NSString
        let start = max(0, range.location - 900)
        let end = min(text.length, range.location + range.length + 100)
        return ["initial": text.substring(to: min(text.length, 500)),
                "latest": text.substring(with: NSRange(location: start, length: min(1000, end - start)))]
    }
}

final class TextInserter {
    private(set) var busy = false
    private var pendingRestore: (() -> Void)?
    func restoreBeforeExit() { pendingRestore?(); pendingRestore = nil }
    func insert(_ text: String, into target: InputSnapshot?, completion: @escaping (Bool, String) -> Void) {
        guard !busy else { completion(false, "上一次粘贴仍在完成，结果已保留"); return }
        guard let target = target else { completion(false, "开始录音时未锁定可编辑输入框，结果已保留"); return }
        busy = true
        attempt(text, target: target, retries: 3, completion: completion)
    }
    private func attempt(_ text: String, target: InputSnapshot, retries: Int, completion: @escaping (Bool, String) -> Void) {
        let resolved: AXUIElement
        do { resolved = try target.resolve() }
        catch {
            // Short accessibility re-layout failures can recover; never move the user's caret.
            if retries > 0 && error.localizedDescription.contains("暂时") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.attempt(text, target: target, retries: retries-1, completion: completion) }; return
            }
            busy = false; completion(false, "未自动输入：\(error.localizedDescription)；结果已保留"); return
        }
        guard CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand,.maskControl,.maskAlternate,.maskShift]).isEmpty else {
            if retries > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.attempt(text, target: target, retries: retries-1, completion: completion) }; return }
            busy = false; completion(false, "未自动输入：仍有修饰键按下；结果已保留"); return
        }
        let clipboard = NSPasteboard.general
        let originalChange = clipboard.changeCount
        var saved: [[NSPasteboard.PasteboardType: Data]] = []
        var bytes = 0
        for item in clipboard.pasteboardItems ?? [] {
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { busy = false; completion(false, "剪贴板内容无法完整保存，请手动复制结果"); return }
                bytes += data.count
                guard bytes <= 16 * 1024 * 1024 else { busy = false; completion(false, "剪贴板内容较大，结果已保留，请手动复制"); return }
                representations[type] = data
            }
            saved.append(representations)
        }
        guard originalChange == clipboard.changeCount, target.unchanged() else {
            busy = false; completion(false, "未自动输入：\(target.failureReason() ?? "剪贴板已变化")；结果已保留"); return
        }
        guard let source = CGEventSource(stateID: .privateState),
            let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            busy = false; completion(false, "无法发送粘贴操作，结果已保留"); return
        }
        clipboard.clearContents(); let wrote = clipboard.setString(text, forType: .string)
        let ourChange = clipboard.changeCount
        func restore() {
            if clipboard.changeCount == ourChange {
                clipboard.clearContents()
                let items = saved.map { representations -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in representations { item.setData(data, forType: type) }
                    return item
                }
                if !items.isEmpty { clipboard.writeObjects(items) }
            }
        }
        pendingRestore = restore
        guard wrote else { restore(); pendingRestore = nil; busy = false; completion(false, "剪贴板写入失败，结果已保留"); return }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(target.pid); up.postToPid(target.pid)
        let expected = (target.value as NSString).replacingCharacters(in: NSRange(location: target.range.location, length: target.range.length), with: text)
        let began = Date()
        func verify() {
            // Reacquire the AX node after web editors re-render their document.
            let nodes = [resolved, focusedElement(target.pid)].compactMap { $0 }
            let verified = nodes.contains { node in
                guard let value = axAttribute(node, kAXValueAttribute) as? String else { return false }
                return value.replacingOccurrences(of: "\r\n", with: "\n") == expected.replacingOccurrences(of: "\r\n", with: "\n")
            }
            if !verified && Date().timeIntervalSince(began) < 3 && clipboard.changeCount == ourChange {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: verify); return
            }
            restore(); self.pendingRestore = nil; self.busy = false
            completion(verified, verified ? "已插入 \(target.name)" : "粘贴已发送，应用未提供可核验结果；未重复粘贴，文字已保留")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: verify)
    }
}
