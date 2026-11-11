import Foundation
import CoreGraphics

@main struct HotkeyTests {
    static func main() {
        // Modifier tap: right Option, quick release fires.
        var tap = ModifierTapState()
        assert(!tap.flags(keyCode:61, down:true, otherModifiers:false, now:1, target:.rightOption))
        assert(tap.flags(keyCode:61, down:false, otherModifiers:false, now:1.2, target:.rightOption))
        // A key pressed while held cancels.
        _ = tap.flags(keyCode:61, down:true, otherModifiers:false, now:2, target:.rightOption)
        tap.keyDown()
        assert(!tap.flags(keyCode:61, down:false, otherModifiers:false, now:2.2, target:.rightOption))
        // Long hold does not fire.
        _ = tap.flags(keyCode:61, down:true, otherModifiers:false, now:3, target:.rightOption)
        assert(!tap.flags(keyCode:61, down:false, otherModifiers:false, now:4, target:.rightOption))
        // Another modifier cancels.
        _ = tap.flags(keyCode:61, down:true, otherModifiers:true, now:5, target:.rightOption)
        assert(!tap.flags(keyCode:61, down:false, otherModifiers:false, now:5.1, target:.rightOption))
        // Left Option does not fire a right-Option binding.
        assert(!tap.flags(keyCode:58, down:false, otherModifiers:false, now:6, target:.rightOption))
        // Stray release does not fire.
        assert(!tap.flags(keyCode:61, down:false, otherModifiers:false, now:7, target:.rightOption))

        // Binding model and display names.
        let dictation = HotkeyBinding(trigger:.modifierTap(.rightOption))
        assert(dictation.display == "右 Option")
        assert(HotkeyBinding.meetingFollowing(dictation) == HotkeyBinding(trigger:.chord(keyCode:46, modifiers:[.rightOption])))
        assert(HotkeyBinding.meetingFollowing(HotkeyBinding(trigger:.chord(keyCode:49, modifiers:[.leftOption]))) == nil)
        let chord = HotkeyBinding(trigger:.chord(keyCode:49, modifiers:[.leftOption]))
        assert(chord.display == "左 Option + Space")
        let fkey = HotkeyBinding(trigger:.chord(keyCode:96, modifiers:[.function]))
        assert(fkey.display == "Fn + F5")

        // Codable round-trip.
        let encoded = try! JSONEncoder().encode(chord)
        let decoded = try! JSONDecoder().decode(HotkeyBinding.self, from: encoded)
        assert(decoded == chord)

        // Chord matching distinguishes physical sides and extra modifiers.
        assert(HotkeyMatcher.matches(chord, keyCode:49, held:[.leftOption]))
        assert(!HotkeyMatcher.matches(chord, keyCode:49, held:[.rightOption]))
        assert(!HotkeyMatcher.matches(chord, keyCode:49, held:[.leftOption,.leftShift]))
        assert(!HotkeyMatcher.matches(chord, keyCode:50, held:[.leftOption]))
        let meeting = HotkeyBinding(trigger:.chord(keyCode:46, modifiers:[.rightOption]))
        assert(HotkeyMatcher.matches(meeting, keyCode:46, held:[.rightOption]))
        assert(!HotkeyMatcher.matches(meeting, keyCode:46, held:[.leftOption]))
        // Held modifiers come from device bits; Fn only from its own key.
        let rightOption = CGEventFlags.maskAlternate.rawValue | 0x40
        let fn = CGEventFlags.maskSecondaryFn.rawValue
        assert(HotkeyModifier.held(in:CGEventFlags(rawValue:rightOption), function:false) == [.rightOption])
        assert(HotkeyModifier.held(in:CGEventFlags(rawValue:fn), function:false).isEmpty)
        assert(HotkeyModifier.held(in:CGEventFlags(rawValue:fn), function:true) == [.function])

        // Chord state fires once and consumes matching down/up.
        var state = HotkeyChordState()
        let down = state.event(binding:meeting, keyCode:46, down:true, held:[.rightOption], repeated:false)
        assert(down.consume && down.fire)
        let repeated = state.event(binding:meeting, keyCode:46, down:true, held:[.rightOption], repeated:true)
        assert(repeated.consume && !repeated.fire)
        let up = state.event(binding:meeting, keyCode:46, down:false, held:[], repeated:false)
        assert(up.consume && !up.fire)
        let strayUp = state.event(binding:meeting, keyCode:46, down:false, held:[], repeated:false)
        assert(!strayUp.consume && !strayUp.fire)

        // The live tap swallows its chords so they never type into the target
        // app (right Option + M would otherwise insert “µ”).
        let hotkey = GlobalHotkey()
        var toggles = 0, meetings = 0
        var reports: [HotkeyTestEvent] = []
        hotkey.onToggle = { toggles += 1 }
        hotkey.onMeeting = { meetings += 1 }
        hotkey.onTestEvent = { reports.append($0) }
        assert(!hotkey.handle(type:.flagsChanged, event:modifierEvent(61, rightOption), now:10))
        assert(hotkey.handle(type:.keyDown, event:keyEvent(46, true, rightOption), now:10.1))
        assert(!hotkey.handle(type:.flagsChanged, event:modifierEvent(61, 0), now:10.2))
        assert(hotkey.handle(type:.keyUp, event:keyEvent(46, false, 0), now:10.3))
        drain()
        assert(meetings == 1 && toggles == 0)
        // A quick right-Option tap toggles and still reaches other apps.
        assert(!hotkey.handle(type:.flagsChanged, event:modifierEvent(61, rightOption), now:20))
        assert(!hotkey.handle(type:.flagsChanged, event:modifierEvent(61, 0), now:20.2))
        drain()
        assert(toggles == 1)
        // Option + A keeps typing “å” and does not toggle.
        _ = hotkey.handle(type:.flagsChanged, event:modifierEvent(61, rightOption), now:30)
        assert(!hotkey.handle(type:.keyDown, event:keyEvent(0, true, rightOption), now:30.1))
        _ = hotkey.handle(type:.keyUp, event:keyEvent(0, false, rightOption), now:30.15)
        _ = hotkey.handle(type:.flagsChanged, event:modifierEvent(61, 0), now:30.2)
        drain()
        assert(toggles == 1)
        // A modifier release the tap never saw must not block later taps.
        _ = hotkey.handle(type:.flagsChanged, event:modifierEvent(56, CGEventFlags.maskShift.rawValue | 0x02), now:40)
        _ = hotkey.handle(type:.flagsChanged, event:modifierEvent(61, rightOption), now:41)
        _ = hotkey.handle(type:.flagsChanged, event:modifierEvent(61, 0), now:41.2)
        drain()
        assert(toggles == 2)
        // While a new shortcut is recorded, every key passes through untouched.
        hotkey.suspended = true
        assert(!hotkey.handle(type:.flagsChanged, event:modifierEvent(61, rightOption), now:50))
        assert(!hotkey.handle(type:.keyDown, event:keyEvent(46, true, rightOption), now:50.1))
        assert(!hotkey.handle(type:.keyUp, event:keyEvent(46, false, rightOption), now:50.15))
        assert(!hotkey.handle(type:.flagsChanged, event:modifierEvent(61, 0), now:50.2))
        drain()
        assert(meetings == 1 && toggles == 2)
        hotkey.suspended = false
        // Test mode reports instead of acting, including a hold that is too long.
        hotkey.testing = true
        _ = hotkey.handle(type:.flagsChanged, event:modifierEvent(61, rightOption), now:60)
        _ = hotkey.handle(type:.flagsChanged, event:modifierEvent(61, 0), now:60.1)
        drain()
        assert(toggles == 2 && reports.last?.matched == true)
        _ = hotkey.handle(type:.flagsChanged, event:modifierEvent(61, rightOption), now:70)
        _ = hotkey.handle(type:.flagsChanged, event:modifierEvent(61, 0), now:71)
        drain()
        assert(toggles == 2 && reports.last?.matched == false && reports.last?.hint != nil)
        hotkey.testing = false

        // Dictation chords are consumed too and stay side-specific.
        let chordHotkey = GlobalHotkey(binding:chord)
        var chordToggles = 0
        chordHotkey.onToggle = { chordToggles += 1 }
        let leftOption = CGEventFlags.maskAlternate.rawValue | 0x20
        assert(chordHotkey.handle(type:.keyDown, event:keyEvent(49, true, leftOption), now:1))
        assert(chordHotkey.handle(type:.keyUp, event:keyEvent(49, false, leftOption), now:1.1))
        assert(!chordHotkey.handle(type:.keyDown, event:keyEvent(49, true, rightOption), now:2))
        drain()
        assert(chordToggles == 1)
        // Fn chords need the Fn key itself; function keys report the Fn flag alone.
        let fnHotkey = GlobalHotkey(binding:fkey)
        var fnToggles = 0
        fnHotkey.onToggle = { fnToggles += 1 }
        _ = fnHotkey.handle(type:.flagsChanged, event:modifierEvent(63, fn), now:1)
        assert(fnHotkey.handle(type:.keyDown, event:keyEvent(96, true, fn), now:1.1))
        _ = fnHotkey.handle(type:.keyUp, event:keyEvent(96, false, fn), now:1.2)
        _ = fnHotkey.handle(type:.flagsChanged, event:modifierEvent(63, 0), now:1.3)
        assert(!fnHotkey.handle(type:.keyDown, event:keyEvent(96, true, fn), now:2))
        drain()
        assert(fnToggles == 1)

        // Validation.
        assert(HotkeyValidation.problem(for:HotkeyBinding(trigger:.chord(keyCode:0, modifiers:[])), meeting:nil) != nil)
        assert(HotkeyValidation.problem(for:HotkeyBinding(trigger:.chord(keyCode:53, modifiers:[])), meeting:nil) != nil)
        assert(HotkeyValidation.problem(for:HotkeyBinding(trigger:.chord(keyCode:49, modifiers:[.rightOption])), meeting:nil) == nil)
        assert(HotkeyValidation.problem(for:HotkeyBinding(trigger:.chord(keyCode:46, modifiers:[.rightOption])), meeting:meeting) != nil)
        assert(HotkeyValidation.problem(for:HotkeyBinding(trigger:.modifierTap(.function)), meeting:nil) == nil)
        assert(HotkeyValidation.conflictWarning(for:HotkeyBinding(trigger:.chord(keyCode:49, modifiers:[.leftOption]))) != nil)
        // Meetings are matched on key presses, so a single modifier never fires.
        assert(HotkeyValidation.meetingProblem(for:HotkeyBinding(trigger:.modifierTap(.leftOption)), dictation:dictation) != nil)
        assert(HotkeyValidation.meetingProblem(for:HotkeyBinding(trigger:.chord(keyCode:46, modifiers:[.leftOption])), dictation:dictation) == nil)
        // A following meeting key is derived before checking for duplicates.
        let leftMeeting = HotkeyBinding(trigger:.chord(keyCode:46, modifiers:[.leftOption]))
        assert(HotkeyBinding.meeting(for:dictation, follows:true, saved:leftMeeting) == meeting)
        assert(HotkeyBinding.meeting(for:meeting, follows:true, saved:leftMeeting) == .defaultMeeting)
        assert(HotkeyBinding.meeting(for:meeting, follows:false, saved:leftMeeting) == leftMeeting)
        assert(HotkeyBinding.meeting(for:HotkeyBinding(trigger:.modifierTap(.rightShift)), follows:true, saved:leftMeeting) == .defaultMeeting)
        assert(HotkeyValidation.problem(for:meeting, meeting:HotkeyBinding.meeting(for:meeting, follows:true, saved:leftMeeting)) != nil)

        print("Hotkey tests passed: modifier tap, left/right, chords, consumption, suspension, stale modifiers, test mode, Fn, validation, conflicts")
    }
}

private func keyEvent(_ code: CGKeyCode, _ down: Bool, _ flags: UInt64) -> CGEvent {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
    event.flags = CGEventFlags(rawValue: flags)
    return event
}

private func modifierEvent(_ code: CGKeyCode, _ flags: UInt64) -> CGEvent {
    let event = keyEvent(code, true, flags)
    event.type = .flagsChanged
    return event
}

// Callbacks are delivered asynchronously on the main queue.
private func drain() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
