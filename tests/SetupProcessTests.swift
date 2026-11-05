import Foundation

@main struct SetupProcessTests {
    static func waitFor(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(condition(), "Setup process did not reach the expected state")
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("freetalk setup process " + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Resources"), support = root.appendingPathComponent("User data")
        let setup = resources.appendingPathComponent("setup")
        try FileManager.default.createDirectory(at: setup, withIntermediateDirectories: true)
        let model: [String: Any] = ["key":"asrModel", "name":"test-model", "title":"Test", "repo":"test/model",
                                    "revision":String(repeating:"a",count:40), "license":"Apache-2.0", "bits":8, "bytes":1, "files":[]]
        try JSONSerialization.data(withJSONObject: ["schema":1,"models":[model]]).write(to: setup.appendingPathComponent("catalog.json"))
        let script = setup.appendingPathComponent("bootstrap.sh")
        try """
        #!/bin/bash
        printf '%s' "$4" > "$1/source"
        printf fragment > "$1/model.partial"
        sleep 20 & child=$!
        trap 'kill "$child" 2>/dev/null; exit 130' TERM INT
        printf ready > "$1/ready"
        printf '%s\\n' '{"event":"progress","stage":"download","message":"Downloading","completed":1,"total":10,"bytes_per_second":1000,"eta_seconds":9}'
        wait "$child"
        """.write(to: script, atomically: true, encoding: .utf8)
        let manager = ModelSetup(support: support, resources: resources)
        var completed = 0
        manager.onComplete = { completed += 1 }
        manager.start(config: [:],source:.mirror)
        waitFor { FileManager.default.fileExists(atPath: support.appendingPathComponent("ready").path) && manager.fraction == 0.1 }
        let selectedSource = try String(contentsOf:support.appendingPathComponent("source"),encoding:.utf8)
        precondition(selectedSource == "mirror")
        precondition(manager.progressText.contains("10.0%") && manager.progressText.contains("/s") && manager.progressText.contains("剩余"))
        precondition(!manager.activityText.isEmpty)
        precondition(manager.models.first?.pageURL(source:.mirror)?.host == "hf-mirror.com")
        manager.cancel()
        waitFor { !manager.busy }
        precondition(completed == 0 && !manager.failed && manager.message.contains("已取消"))
        precondition(manager.progressText.contains("10.0%") && !manager.progressText.contains("/s"))
        let fragment = try String(contentsOf: support.appendingPathComponent("model.partial"), encoding: .utf8)
        precondition(fragment == "fragment")

        try """
        printf '%s\\n' '{"event":"progress","stage":"download","completed":5,"total":10,"bytes_per_second":1000,"eta_seconds":5}'
        printf '%s\\n' '{"event":"error","message":"Simulated network failure"}'
        exit 7
        """.write(to: script, atomically: true, encoding: .utf8)
        manager.start(config: [:])
        waitFor { !manager.busy }
        precondition(manager.failed && completed == 0 && manager.message.contains("Simulated network failure"))
        precondition(manager.progressText.contains("50.0%") && !manager.progressText.contains("剩余"))

        try """
        printf '%s\\n' '{"event":"complete","message":"Verified","completed":10,"total":10}'
        """.write(to: script, atomically: true, encoding: .utf8)
        manager.start(config: [:])
        waitFor { !manager.busy }
        precondition(completed == 1 && !manager.failed && manager.fraction == 1)
        precondition(manager.activityText.isEmpty)
        print("Setup process passed: source choice, progress/rate/ETA, cancellation, partial preservation, failed exit, retry completion, spaced paths")
    }
}
