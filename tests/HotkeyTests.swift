import Foundation

@main struct HotkeyTests {
    static func main() {
        var tap = OptionTapState()
        assert(!tap.flags(code:61,rightDown:true,otherModifiers:false,now:1))
        assert(tap.flags(code:61,rightDown:false,otherModifiers:false,now:1.2))
        _ = tap.flags(code:61,rightDown:true,otherModifiers:false,now:2)
        tap.keyDown()
        assert(!tap.flags(code:61,rightDown:false,otherModifiers:false,now:2.2))
        _ = tap.flags(code:61,rightDown:true,otherModifiers:false,now:3)
        assert(!tap.flags(code:61,rightDown:false,otherModifiers:false,now:4))
        _ = tap.flags(code:61,rightDown:true,otherModifiers:true,now:5)
        assert(!tap.flags(code:61,rightDown:false,otherModifiers:false,now:5.1))
        assert(!tap.flags(code:58,rightDown:false,otherModifiers:false,now:6))
        assert(!tap.flags(code:61,rightDown:false,otherModifiers:false,now:7))
        var meeting = MeetingChordState()
        assert(!meeting.event(code:46,down:true,rightOption:false,otherModifiers:false,repeated:false).consume)
        assert(!meeting.event(code:46,down:true,rightOption:true,otherModifiers:true,repeated:false).consume)
        assert(!meeting.event(code:46,down:true,rightOption:true,otherModifiers:false,repeated:true).fire)
        let start = meeting.event(code:46,down:true,rightOption:true,otherModifiers:false,repeated:false)
        assert(start.consume && start.fire)
        assert(!meeting.event(code:46,down:true,rightOption:true,otherModifiers:false,repeated:true).fire)
        assert(!meeting.event(code:47,down:true,rightOption:true,otherModifiers:false,repeated:false).consume)
        assert(meeting.event(code:46,down:false,rightOption:false,otherModifiers:false,repeated:false).consume)
        assert(!meeting.event(code:46,down:false,rightOption:false,otherModifiers:false,repeated:false).consume)
        assert(meeting.event(code:46,down:true,rightOption:true,otherModifiers:false,repeated:false).fire)
        print("Hotkey transitions passed: tap, chord, hold, modifiers, left Option, stray release")
    }
}
