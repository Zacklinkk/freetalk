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
        print("Input identity passed: recreated node accepted only with matching path/window/document; changed target rejected; paste verification tolerates representation differences")
    }
}
