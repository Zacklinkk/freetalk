import Foundation
@main struct InputIdentityTests {
    static func main() {
        func identity(id: String = "draft", path: [Int] = [0,2,1], title: String = "Draft", doc: String = "https://example.test", x: Double = 10, label: String = "Input") -> InputIdentity {
            InputIdentity(role: "AXTextArea", identifier: id, label: label, path: path, windowTitle: title, document: doc, bounds: CGRect(x:x,y:20,width:400,height:100))
        }
        let frozen = identity()
        precondition(frozen.matchesReplacement(identity()))
        precondition(!frozen.matchesReplacement(identity(id: "other")))
        precondition(!frozen.matchesReplacement(identity(path: [0,3,1])))
        precondition(!frozen.matchesReplacement(identity(title: "Another draft")))
        precondition(!frozen.matchesReplacement(identity(doc: "https://other.test")))
        precondition(!identity(id: "").matchesReplacement(identity(id: "", x: 300)))
        precondition(identity(id: "").matchesReplacement(identity(id: "", x: 11)))
        precondition(!identity(path: []).matchesReplacement(identity(path: [])))
        // Paste verification: representation-only differences still confirm the paste.
        let before = "你好", insert = "，明天下午三点开会", expected = before + insert
        for (observed, verified, reason) in [
            (expected, true, "exact"),
            (expected + "\n", true, "normalized"),                                   // block editors add a trailing newline
            (expected.replacingOccurrences(of:"下午", with:"下午"), true, "exact"),
            ("你好\u{200B}，明天下午三点开会", true, "normalized"),                    // zero-width character
            ("你好，明天下午三点开会\n\n", true, "normalized"),
            ("你好\n，明天下午三点开会", true, "contains_insert"),                      // editor reflowed around the paste
            (before, false, "unchanged"),                                             // paste never landed
            ("", false, "cleared"),
            ("完全不同的内容", false, "different"),
        ] {
            let result = InsertionCheck.check(original: before, inserted: insert, expected: expected, observed: observed)
            precondition(result.verified == verified && result.reason == reason, "\(observed.debugDescription) -> \(result)")
        }
        precondition(InsertionCheck.check(original: before, inserted: insert, expected: expected, observed: nil) == (false, "no_value"))
        // Web editors report spaces as non-breaking spaces.
        precondition(InsertionCheck.check(original: "", inserted: "run SFT now", expected: "run SFT now", observed: "run\u{00A0}SFT\u{00A0}now") == (true, "normalized"))
        // A short insert that already existed in the field is not proof of a paste.
        precondition(!InsertionCheck.check(original: "好的好的", inserted: "好的", expected: "好的好的好的", observed: "好的好的").verified)
        // The caret check ignores changes elsewhere in the field but not at the caret.
        func r(_ location: Int, _ length: Int = 0) -> CFRange { CFRange(location: location, length: length) }
        let draft = "请帮我看一下这段代码。"                                   // caret at the end
        let n = (draft as NSString).length
        precondition(InsertionCheck.caretUnchanged(original: draft, range: r(n), current: draft, currentRange: r(n)))
        // Output was added above a longer draft; the caret index moved, its surroundings did not.
        let longDraft = "上一段已经写好的内容，保持不变。" + draft
        let streamed = "第一轮输出……第二轮输出……\n" + longDraft
        precondition(InsertionCheck.caretUnchanged(original: longDraft, range: r((longDraft as NSString).length), current: streamed, currentRange: r((streamed as NSString).length)))
        // In a short field the window reaches the field start, so text added there counts.
        precondition(!InsertionCheck.caretUnchanged(original: draft, range: r(n), current: "新" + draft, currentRange: r(n + 1)))
        // A block-ending newline after the caret is not a change.
        precondition(InsertionCheck.caretUnchanged(original: draft, range: r(n), current: draft + "\n", currentRange: r(n)))
        // Text appended far after the caret.
        let long = String(repeating: "旧", count: 40) + "|" + String(repeating: "尾", count: 40)
        let at = 40
        precondition(InsertionCheck.caretUnchanged(original: long, range: r(at), current: long + "新加的内容", currentRange: r(at)))
        // Invisible characters an editor adds are not a change.
        precondition(InsertionCheck.caretUnchanged(original: "a b", range: r(1), current: "a\u{00A0}b", currentRange: r(1)))
        // The user typed at the caret, moved it, or the selection changed: refuse.
        precondition(!InsertionCheck.caretUnchanged(original: draft, range: r(n), current: draft + "我又打了字", currentRange: r(n + 5)))
        precondition(!InsertionCheck.caretUnchanged(original: draft, range: r(n), current: draft, currentRange: r(2)))
        precondition(!InsertionCheck.caretUnchanged(original: draft, range: r(2, 3), current: draft, currentRange: r(2, 1)))
        // An empty field that is now filled, or emptied, is a change.
        precondition(!InsertionCheck.caretUnchanged(original: "", range: r(0), current: "别人发来的内容", currentRange: r(0)))
        precondition(!InsertionCheck.caretUnchanged(original: draft, range: r(n), current: "", currentRange: r(0)))
        // Out-of-range selections fail closed.
        precondition(!InsertionCheck.caretUnchanged(original: draft, range: r(n + 1), current: draft, currentRange: r(n)))
        print("Input identity passed: recreated node accepted only with matching path/window/document; changed target rejected; paste verification tolerates representation differences; caret check ignores changes away from the caret")
    }
}
