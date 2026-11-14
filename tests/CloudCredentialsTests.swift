import Foundation

@main struct CloudCredentialsTests {
    static func main() throws {
        // Key and headers round-trip through one Keychain value.
        let full = CloudCredentials(key: "k-test", headers: ["x-gateway": "{\"user\":\"u\"}"])
        let decoded = CloudCredentials.decode(full.encoded())
        precondition(decoded?.credentials == full && decoded?.legacy == false)
        precondition(CloudCredentials.decode(CloudCredentials(key: "k").encoded())?.credentials.headers == [:])
        // Values written before 0.6 are the bare key; they are read and flagged for the merge.
        let old = CloudCredentials.decode("  sk-old-value \n")
        precondition(old?.credentials == CloudCredentials(key: "sk-old-value") && old?.legacy == true)
        // A JSON value without a key is not mistaken for credentials, and empty values are nothing.
        precondition(CloudCredentials.decode("{\"headers\":{}}")?.legacy == true)
        precondition(CloudCredentials.decode("") == nil && CloudCredentials.decode("   ") == nil)
        // Non-string header values are dropped rather than sent.
        let mixed = CloudCredentials.decode("{\"key\":\"k\",\"headers\":{\"a\":\"1\",\"b\":2}}")
        precondition(mixed?.credentials.headers == ["a": "1"])
        // The worker payload never reads the Keychain: nothing cached means nil.
        var settings = CloudEditorSettings(); settings.enabled = true; settings.baseURL = "https://example.invalid/v1-\(UUID().uuidString)"; settings.model = "m"
        precondition(settings.payload() == nil)
        let payload = settings.payload(with: full)
        precondition(payload["api_key"] as? String == "k-test" && (payload["headers"] as? [String: String]) == full.headers)
        precondition(CloudEditorSettings.describe(fallback: "keychain_pending").contains("钥匙串"))
        print("Cloud credentials passed: single-item round trip, legacy bare key, header filtering, payload without Keychain access")
    }
}
