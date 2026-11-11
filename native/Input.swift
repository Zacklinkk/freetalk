import AppKit
import ApplicationServices
import Carbon

// MARK: - Hotkey model

enum HotkeyModifier: Int, Codable, CaseIterable {
    case leftCommand = 55, rightCommand = 54
    case leftShift = 56, rightShift = 60
    case leftOption = 58, rightOption = 61
    case leftControl = 59, rightControl = 62
    case function = 63

    var genericFlag: CGEventFlags {
        switch self {
        case .leftCommand, .rightCommand: return .maskCommand
        case .leftShift, .rightShift: return .maskShift
        case .leftOption, .rightOption: return .maskAlternate
        case .leftControl, .rightControl: return .maskControl
        case .function: return .maskSecondaryFn
        }
    }
    var deviceBit: UInt64 {
        switch self {
        case .leftCommand: return 0x08
        case .rightCommand: return 0x10
        case .leftShift: return 0x02
        case .rightShift: return 0x04
        case .leftOption: return 0x20
        case .rightOption: return 0x40
        case .leftControl: return 0x01
        case .rightControl: return 0x2000
        case .function: return 0
        }
    }
    var display: String {
        switch self {
        case .leftCommand: return "左 Command"
        case .rightCommand: return "右 Command"
        case .leftShift: return "左 Shift"
        case .rightShift: return "右 Shift"
        case .leftOption: return "左 Option"
        case .rightOption: return "右 Option"
        case .leftControl: return "左 Control"
        case .rightControl: return "右 Control"
        case .function: return "Fn"
        }
    }
    func isDown(in flags: CGEventFlags) -> Bool {
        if self == .function { return flags.contains(.maskSecondaryFn) }
        return flags.rawValue & deviceBit != 0
    }
    /// Physical modifiers held during an event. Side-specific keys are read
    /// from the device bits of every event, so a release the tap never saw
    /// cannot leave a modifier stuck. Arrow and function keys report the Fn
    /// flag on their own, so Fn is only counted when its key was pressed.
    static func held(in flags: CGEventFlags, function: Bool) -> Set<HotkeyModifier> {
        var result = Set(allCases.filter { $0 != .function && flags.rawValue & $0.deviceBit != 0 })
        if function { result.insert(.function) }
        return result
    }
    static func ordered(_ modifiers: Set<HotkeyModifier>) -> [HotkeyModifier] {
        [.leftControl, .rightControl, .leftOption, .rightOption, .leftShift, .rightShift, .leftCommand, .rightCommand, .function]
            .filter { modifiers.contains($0) }
    }
}

struct HotkeyBinding: Codable, Equatable {
    enum Trigger: Codable, Equatable {
        case modifierTap(HotkeyModifier)
        case chord(keyCode: Int, modifiers: [HotkeyModifier])
    }
    var trigger: Trigger
    init(trigger: Trigger) { self.trigger = trigger }

    static let defaultDictation = HotkeyBinding(trigger: .modifierTap(.rightOption))
    static let defaultMeeting = HotkeyBinding(trigger: .chord(keyCode: 46, modifiers: [.rightOption]))

    var display: String {
        switch trigger {
        case .modifierTap(let modifier):
            return modifier.display
        case .chord(let keyCode, let modifiers):
            let prefix = modifiers.map(\.display)
            return (prefix + [HotkeyKeyName.name(for: keyCode)]).joined(separator: " + ")
        }
    }
    var isModifierTap: Bool {
        if case .modifierTap = trigger { return true }
        return false
    }
    static func meetingFollowing(_ main: HotkeyBinding) -> HotkeyBinding? {
        guard case .modifierTap(let modifier) = main.trigger else { return nil }
        return HotkeyBinding(trigger: .chord(keyCode: 46, modifiers: [modifier]))
    }
    /// The meeting shortcut in effect for a dictation shortcut.
    static func meeting(for dictation: HotkeyBinding, follows: Bool, saved: HotkeyBinding) -> HotkeyBinding {
        guard follows else { return saved }
        // A Shift tap would derive Shift + M and swallow every capital M.
        if let derived = meetingFollowing(dictation), HotkeyValidation.problem(for: derived, meeting: nil) == nil { return derived }
        return .defaultMeeting
    }
    static func load(_ key: String) -> HotkeyBinding? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HotkeyBinding.self, from: data)
    }
    func save(_ key: String) {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: key) }
    }
}

enum HotkeyKeyName {
    private static let names: [Int: String] = [
        0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",
        16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",
        30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",
        45:"N",46:"M",47:".",50:"`",36:"Return",48:"Tab",49:"Space",51:"Delete",53:"Escape",
        55:"左 Command",54:"右 Command",56:"左 Shift",60:"右 Shift",58:"左 Option",61:"右 Option",59:"左 Control",62:"右 Control",63:"Fn",
        71:"Clear",76:"Enter",114:"Help",115:"Home",116:"Page Up",117:"Forward Delete",119:"End",121:"Page Down",
        123:"←",124:"→",125:"↓",126:"↑",
        122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",
        103:"F11",111:"F12",105:"F13",107:"F14",113:"F15",106:"F16",64:"F17",79:"F18",80:"F19",90:"F20"
    ]
    static func name(for keyCode: Int) -> String { names[keyCode] ?? "键码 \(keyCode)" }
}

enum HotkeyMatcher {
    static func matches(_ binding: HotkeyBinding, keyCode: Int, held: Set<HotkeyModifier>) -> Bool {
        guard case .chord(let expectedKey, let expectedModifiers) = binding.trigger else { return false }
        return expectedKey == keyCode && Set(expectedModifiers) == held
    }
}

enum HotkeyValidation {
    /// The meeting shortcut is matched on key presses, so it must be a chord.
    static func meetingProblem(for binding: HotkeyBinding, dictation: HotkeyBinding) -> String? {
        if binding.isModifierTap { return "会议快捷键需要组合键，例如 右 Option + M" }
        return problem(for: binding, meeting: dictation)
    }
    static func problem(for binding: HotkeyBinding, meeting: HotkeyBinding?) -> String? {
        if let meeting, binding == meeting { return "会议快捷键不能与语音输入快捷键相同" }
        switch binding.trigger {
        case .modifierTap:
            return nil
        case .chord(let keyCode, let modifiers):
            if keyCode == 53 && modifiers.isEmpty { return "Esc 用于取消录音，不能单独作为快捷键" }
            if modifiers.isEmpty {
                return HotkeyKeyName.isFunctionKey(keyCode) ? nil : "请按住 Command/Control/Option/Fn，或选择 F1–F20"
            }
            let onlyShift = modifiers.allSatisfy { $0.genericFlag == .maskShift }
            if onlyShift && HotkeyKeyName.isTypingKey(keyCode) {
                return "Shift + 字母/数字会影响正常输入，请改用其他修饰键"
            }
            return nil
        }
    }
    static func conflictWarning(for binding: HotkeyBinding) -> String? {
        if binding.isModifierTap {
            return "单独修饰键可能与输入法或系统手势冲突，建议用“测试快捷键”确认"
        }
        guard case .chord(let keyCode, let modifiers) = binding.trigger else { return nil }
        let generic = modifiers.reduce(UInt64(0)) { $0 | $1.genericFlag.rawValue }
        let option = CGEventFlags.maskAlternate.rawValue
        let command = CGEventFlags.maskCommand.rawValue
        let control = CGEventFlags.maskControl.rawValue
        if keyCode == 49 && generic == command { return "Command + Space 默认用于聚焦搜索（Spotlight）" }
        if keyCode == 49 && generic == control { return "Control + Space 默认用于切换输入法" }
        if keyCode == 49 && generic == option { return "Option + Space 可能已被 ChatGPT 等应用占用" }
        if keyCode == 48 && generic == command { return "Command + Tab 默认用于切换应用" }
        if keyCode == 12 && generic == command { return "Command + Q 默认用于退出应用" }
        if keyCode == 13 && generic == command { return "Command + W 默认用于关闭窗口" }
        if keyCode == 4 && generic == command { return "Command + H 默认用于隐藏应用" }
        if generic == option && HotkeyKeyName.isTypingKey(keyCode) {
            return "Option + 字母会拦截该字符的正常输入（例如 Option + M 输入 µ）"
        }
        return nil
    }
}

extension HotkeyKeyName {
    static func isFunctionKey(_ keyCode: Int) -> Bool {
        [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90].contains(keyCode)
    }
    static func isTypingKey(_ keyCode: Int) -> Bool {
        // Letters, digits, punctuation. Navigation, function and whitespace
        // keys are safe to claim without breaking text input.
        let safe: Set<Int> = [36,48,49,51,53,71,76,114,115,116,117,119,121,123,124,125,126]
        return !safe.contains(keyCode) && !isFunctionKey(keyCode)
    }
}

// MARK: - State machines

struct ModifierTapState {
    private var began: TimeInterval?
    private var chord = false
    mutating func keyDown() { if began != nil { chord = true } }
    mutating func cancel() { if began != nil { chord = true } }
    mutating func flags(keyCode: Int, down: Bool, otherModifiers: Bool, now: TimeInterval, target: HotkeyModifier) -> Bool {
        guard keyCode == target.rawValue else {
            if began != nil { chord = true }
            return false
        }
        if down {
            began = now
            chord = otherModifiers
            return false
        }
        let valid = began.map { now - $0 <= 0.45 && now >= $0 } ?? false
        let fire = valid && !chord && !otherModifiers
        began = nil; chord = false
        return fire
    }
}

// A chord fires once on key-down and consumes its matching key-up even if the
// modifiers were released first.
struct HotkeyChordState {
    private var claimedKey: Int?
    mutating func event(binding: HotkeyBinding, keyCode: Int, down: Bool, held: Set<HotkeyModifier>, repeated: Bool) -> (consume: Bool, fire: Bool) {
        if !down {
            let wasClaimed = claimedKey == keyCode
            if wasClaimed { claimedKey = nil }
            return (wasClaimed, false)
        }
        if claimedKey == keyCode { return (true, false) }
        guard !repeated, HotkeyMatcher.matches(binding, keyCode: keyCode, held: held) else { return (false, false) }
        claimedKey = keyCode
        return (true, true)
    }
}

struct HotkeyTestEvent {
    let description: String
    let matched: Bool
    let elapsed: TimeInterval?
    /// Why a press of the configured key did not count.
    var hint: String? = nil
}

final class GlobalHotkey {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var dictationTap = ModifierTapState()
    private var dictationChord = HotkeyChordState()
    private var meetingChord = HotkeyChordState()
    private var functionHeld = false
    private var modifierBegan: TimeInterval?
    private var lastUnmatchedTest: TimeInterval = 0

    private(set) var binding: HotkeyBinding
    private(set) var meetingBinding: HotkeyBinding
    private(set) var failure: String?
    var onToggle: (() -> Void)?
    var onMeeting: (() -> Void)?
    var onEscape: (() -> Void)?
    var onTestEvent: ((HotkeyTestEvent) -> Void)?
    var testing = false
    /// While a new shortcut is being recorded, keys pass through untouched so
    /// the recorder receives them and no shortcut action fires.
    var suspended = false { didSet { reset() } }
    var active: Bool { tap != nil }

    init(binding: HotkeyBinding = .defaultDictation, meetingBinding: HotkeyBinding = .defaultMeeting) {
        self.binding = binding
        self.meetingBinding = meetingBinding
    }

    func update(binding: HotkeyBinding, meetingBinding: HotkeyBinding) {
        self.binding = binding
        self.meetingBinding = meetingBinding
        reset()
    }

    @discardableResult
    func start() -> Bool {
        stop()
        // Creating an active tap sends TCC a real (non-preflight) request for
        // event access, which may prompt. Without either permission it cannot
        // succeed, so do not prompt implicitly at launch or on retries.
        guard AXIsProcessTrusted() || CGPreflightListenEventAccess() else {
            failure = Self.diagnosis()
            return false
        }
        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, pointer in
                guard let pointer = pointer else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<GlobalHotkey>.fromOpaque(pointer).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    owner.reset()
                    return Unmanaged.passUnretained(event)
                }
                return owner.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap = tap else {
            failure = Self.diagnosis()
            return false
        }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        failure = nil
        return true
    }

    func stop() {
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap = tap { CFMachPortInvalidate(tap) }
        source = nil; tap = nil; failure = nil
        reset()
    }

    private func reset() {
        dictationTap = ModifierTapState()
        dictationChord = HotkeyChordState()
        meetingChord = HotkeyChordState()
        functionHeld = false
        modifierBegan = nil
    }

    private static func diagnosis() -> String {
        // An active (filtering) tap is granted through Accessibility; Input
        // Monitoring only explains a refused tap when Accessibility is present.
        if !AXIsProcessTrusted() { return "活动事件监听需要辅助功能权限" }
        if !CGPreflightListenEventAccess() { return "输入监控授权记录可能已失效；若系统设置中开关已打开，请移除后重新添加 freetalk" }
        return "系统未允许创建事件监听"
    }

    /// Handles one event from the tap, which runs on the main run loop.
    /// Returns true when the event is part of a shortcut and must not reach
    /// the focused app.
    func handle(type: CGEventType, event: CGEvent, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard !suspended else { return false }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        if type == .flagsChanged && code == HotkeyModifier.function.rawValue { functionHeld = flags.contains(.maskSecondaryFn) }
        else if !flags.contains(.maskSecondaryFn) { functionHeld = false }
        let held = HotkeyModifier.held(in: flags, function: functionHeld)
        if type == .flagsChanged {
            guard let modifier = HotkeyModifier(rawValue: code) else { return false }
            let down = held.contains(modifier)
            guard let target = binding.modifierTap, modifier == target else {
                dictationTap.cancel()
                if testing && down { report(HotkeyTestEvent(description: modifier.display, matched: false, elapsed: nil)) }
                return false
            }
            let fire = dictationTap.flags(keyCode: code, down: down, otherModifiers: !held.subtracting([target]).isEmpty, now: now, target: target)
            if down { modifierBegan = now }
            if testing {
                if fire {
                    report(HotkeyTestEvent(description: target.display, matched: true, elapsed: modifierBegan.map { now - $0 }))
                } else {
                    report(HotkeyTestEvent(description: target.display, matched: false, elapsed: nil,
                                           hint: down ? nil : "按住超过 0.45 秒，或同时按了其他键"))
                }
            } else if fire {
                DispatchQueue.main.async { self.onToggle?() }
            }
            if !down { modifierBegan = nil }
            return false
        }
        guard type == .keyDown || type == .keyUp else { return false }
        let down = type == .keyDown
        let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if down { dictationTap.keyDown() }

        let meeting = meetingChord.event(binding: meetingBinding, keyCode: code, down: down, held: held, repeated: repeated)
        if meeting.fire {
            if testing {
                report(HotkeyTestEvent(description: "会议键 \(meetingBinding.display)", matched: false, elapsed: nil))
            } else {
                DispatchQueue.main.async { self.onMeeting?() }
            }
        }
        if meeting.consume { return true }

        if !binding.isModifierTap {
            let dictation = dictationChord.event(binding: binding, keyCode: code, down: down, held: held, repeated: repeated)
            if dictation.fire {
                if testing {
                    report(HotkeyTestEvent(description: binding.display, matched: true, elapsed: nil))
                } else {
                    DispatchQueue.main.async { self.onToggle?() }
                }
            }
            if dictation.consume { return true }
        }

        if down && code == 53 {
            if testing {
                report(HotkeyTestEvent(description: "Escape", matched: false, elapsed: nil))
            } else {
                DispatchQueue.main.async { self.onEscape?() }
            }
            return false
        }

        if testing && down && now - lastUnmatchedTest > 0.5 {
            lastUnmatchedTest = now
            // Name the physical sides so a left/right mix-up is visible.
            let pressed = HotkeyBinding(trigger: .chord(keyCode: code, modifiers: HotkeyModifier.ordered(held)))
            report(HotkeyTestEvent(description: pressed.display, matched: false, elapsed: nil))
        }
        return false
    }

    private func report(_ event: HotkeyTestEvent) {
        DispatchQueue.main.async { self.onTestEvent?(event) }
    }

    deinit { stop() }
}

private extension HotkeyBinding {
    var modifierTap: HotkeyModifier? {
        if case .modifierTap(let modifier) = trigger { return modifier }
        return nil
    }
}

func axAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

private var requestedAccessibility = Set<String>()

func focusedElement(_ pid: pid_t) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.2)
    // Chromium/Electron may expose only the shell until an assistive client
    // requests its accessibility tree. This does not grant macOS permission.
    if let running = NSRunningApplication(processIdentifier:pid), let bundle = running.bundleIdentifier,
       bundle.contains("doubao") || bundle.contains("Chrome") || bundle.contains("comate") {
        let identity = "\(pid):\(running.launchDate?.timeIntervalSince1970 ?? 0)"
        if !requestedAccessibility.contains(identity) {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            if requestedAccessibility.count > 128 { requestedAccessibility.removeAll() }
            requestedAccessibility.insert(identity)
        }
    }
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
        let application = NSRunningApplication(processIdentifier:pid)
        let bundle = application?.bundleIdentifier ?? ""
        let scene: String
        if ["terminal","iterm"].contains(where:bundle.lowercased().contains) { scene = "terminal" }
        else if ["codex","comate","vscode","xcode","cursor"].contains(where:bundle.lowercased().contains) { scene = "development" }
        else if ["doubao","chat","hi.mac","wechat"].contains(where:bundle.lowercased().contains) { scene = "conversation" }
        else { scene = "general" }
        return ["app":name,"scene":scene,"window_title":identity.windowTitle,
                "nearby":UserDefaults.standard.bool(forKey:"windowContextEnabled") ? nearbyText() : "",
                "initial": text.substring(to: min(text.length, 500)),
                "latest": text.substring(with: NSRange(location: start, length: min(1000, end - start)))]
    }
    private func nearbyText() -> String {
        // Bounded to the selected input's containing pane and current window.
        // Read once at recording start; no clipboard, screenshots or background monitoring.
        guard let window = window, let frame = axRect(window) else { return "" }
        var root = element
        for _ in 0..<4 {
            guard let parent = axAttribute(root,kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            let node = parent as! AXUIElement
            if CFEqual(node,window) { break }; root = node
        }
        var queue = [root], values = [String](), count = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 0.08
        while !queue.isEmpty && count < 80 && ProcessInfo.processInfo.systemUptime < deadline && values.joined().count < 1800 {
            let node = queue.removeFirst(); count += 1
            AXUIElementSetMessagingTimeout(node,0.02)
            if (axAttribute(node,kAXSubroleAttribute) as? String ?? "").localizedCaseInsensitiveContains("secure") { continue }
            if let rect = axRect(node), !rect.intersects(frame) { continue }
            if let value = axAttribute(node,kAXValueAttribute) as? String, !value.isEmpty, !values.contains(value) {
                values.append(String(value.prefix(600)))
            }
            if let children = axAttribute(node,kAXVisibleChildrenAttribute) as? [AXUIElement] ?? axAttribute(node,kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf:children.prefix(max(0,80-count-queue.count)))
            }
        }
        return String(values.joined(separator:"\n").prefix(1800))
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
        guard let source = CGEventSource(stateID: .combinedSessionState),
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
        // Dispatch through the normal keyboard path. Direct per-PID events can
        // bypass Chromium's input/IME routing even when manual Cmd-V works.
        guard target.unchanged() else { restore(); pendingRestore=nil; busy=false; completion(false,"目标已变化，结果已保留"); return }
        down.post(tap:.cghidEventTap); up.post(tap:.cghidEventTap)
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
