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
        print("Input identity passed: recreated node accepted only with matching path/window/document; changed target rejected")
    }
}
