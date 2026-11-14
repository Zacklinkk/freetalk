import AppKit
import Security

/// Optional cloud model for dictation cleanup. Settings live in UserDefaults;
/// the API key and any gateway headers live only in the Keychain.
struct CloudEditorSettings {
    static let service = "io.github.zacklinkk.freetalk.cleanup"
    static let protocols = [("openai", "OpenAI 兼容（/chat/completions）"), ("anthropic", "Anthropic 兼容（/v1/messages）")]
    static let timeouts: [Double] = [5, 8, 12, 20]

    var enabled = false
    var protocolName = "openai"
    var baseURL = ""
    var model = ""
    var timeout: Double = 8

    static func load() -> Self {
        let d = UserDefaults.standard
        var s = Self()
        s.enabled = d.bool(forKey: "cloudCleanupEnabled")
        s.protocolName = protocols.map(\.0).contains(d.string(forKey: "cloudCleanupProtocol") ?? "") ? d.string(forKey: "cloudCleanupProtocol")! : "openai"
        s.baseURL = d.string(forKey: "cloudCleanupBaseURL") ?? ""
        s.model = d.string(forKey: "cloudCleanupModel") ?? ""
        let saved = d.double(forKey: "cloudCleanupTimeout")
        s.timeout = timeouts.contains(saved) ? saved : 8
        return s
    }

    func save() {
        let d = UserDefaults.standard
        d.set(enabled, forKey: "cloudCleanupEnabled"); d.set(protocolName, forKey: "cloudCleanupProtocol")
        d.set(baseURL, forKey: "cloudCleanupBaseURL"); d.set(model, forKey: "cloudCleanupModel"); d.set(timeout, forKey: "cloudCleanupTimeout")
    }

    /// The same endpoint rules as the worker, checked before anything is saved.
    static func validated(baseURL raw: String) throws -> String {
        let base = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base), let host = url.host,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw VoiceError.message("请输入有效的 HTTPS API 地址，不要将密钥写在 URL 中")
        }
        return base
    }

    /// Gateway headers are optional JSON; validate before storing.
    static func validated(headers raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "" }
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              object.allSatisfy({ $0.key.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil && $0.value is String }) else {
            throw VoiceError.message("额外请求头需为 JSON 对象，例如 {\"x-gateway\":\"值\"}")
        }
        return text
    }

    /// The request payload for the worker, or nil when the cloud editor is off,
    /// incomplete, or its credentials have not been read from the Keychain yet.
    /// Never touches the Keychain itself, so it cannot block on a system prompt.
    func payload() -> [String: Any]? {
        guard enabled, !baseURL.isEmpty, !model.isEmpty else { return nil }
        guard let credentials = CloudCredentialStore.cached(baseURL) else { CloudCredentialStore.prefetch(baseURL); return nil }
        return payload(with: credentials)
    }

    func payload(with credentials: CloudCredentials) -> [String: Any] {
        var value: [String: Any] = ["protocol": protocolName, "base_url": baseURL, "model": model, "api_key": credentials.key, "timeout_seconds": timeout]
        if !credentials.headers.isEmpty { value["headers"] = credentials.headers }
        return value
    }

    /// Whether a secret is stored, without reading it. Reading the value can
    /// show a Keychain approval dialog; checking attributes never does, so the
    /// settings page uses this and never blocks the main thread on a prompt.
    static func hasSecret(_ account: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Complete enough to try: switched on, endpoint, model and a stored key.
    var configured: Bool { enabled && !baseURL.isEmpty && !model.isEmpty && Self.hasSecret(baseURL) }

    /// Reading a value can show a Keychain prompt; call it off the main thread.
    static func secret(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setSecret(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        if value.isEmpty { SecItemDelete(query as CFDictionary); return }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw VoiceError.message("无法将 API Key 保存到钥匙串") }
            return
        }
        guard status == errSecSuccess else { throw VoiceError.message("钥匙串更新失败（\(status)）") }
    }

    /// Short, user-facing wording for a worker fallback reason code.
    static func describe(fallback reason: String) -> String {
        switch reason {
        case "keychain_pending": return "正在等待钥匙串授权"
        case "timeout": return "云端整理超时"
        case "network": return "无法连接云端整理服务"
        case "redirect": return "云端地址发生重定向"
        case "invalid_config": return "云端整理配置无效"
        case "invalid_json", "invalid_plan", "invalid_response", "empty_response", "truncated": return "云端返回格式无法使用"
        case "http_401", "http_403": return "云端拒绝了 API Key"
        case "http_429": return "云端请求过于频繁"
        default: return reason.hasPrefix("http_") ? "云端服务返回 \(reason.dropFirst(5))" : "云端整理不可用"
        }
    }
}

/// API key and gateway headers for one endpoint.
struct CloudCredentials: Equatable {
    var key: String
    var headers: [String: String] = [:]

    /// One Keychain value holds both, so macOS asks at most once per build.
    /// freetalk is signed without an Apple team ID, so the Keychain partition
    /// list records each build's code hash: a new build must be allowed again.
    func encoded() -> String {
        let object: [String: Any] = ["key": key, "headers": headers]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// The stored value, or nil if empty. Before version 0.6 the item held the
    /// bare key and the headers lived in a second "#headers" item; `legacy`
    /// tells the caller to merge that item in once.
    static func decode(_ text: String) -> (credentials: CloudCredentials, legacy: Bool)? {
        if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
           let key = object["key"] as? String, !key.isEmpty {
            let headers = (object["headers"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
            return (CloudCredentials(key: key, headers: headers), false)
        }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : (CloudCredentials(key: key), true)
    }
}

/// Reads credentials once per launch, off the main thread, and keeps them in
/// memory. A Keychain prompt then appears at most once per launch (and only
/// for a new build), never in the middle of starting a recording.
enum CloudCredentialStore {
    private static let lock = NSLock()
    private static var cache: [String: CloudCredentials] = [:]
    private static var loading: Set<String> = []

    static func cached(_ endpoint: String) -> CloudCredentials? { lock.lock(); defer { lock.unlock() }; return cache[endpoint] }
    static var isLoading: Bool { lock.lock(); defer { lock.unlock() }; return !loading.isEmpty }

    /// Start a background read unless one is running or the value is cached.
    static func prefetch(_ endpoint: String, completion: ((CloudCredentials?) -> Void)? = nil) {
        lock.lock()
        if let value = cache[endpoint] { lock.unlock(); completion.map { done in DispatchQueue.main.async { done(value) } }; return }
        let started = loading.insert(endpoint).inserted
        lock.unlock()
        guard started else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let value = read(endpoint)
            lock.lock(); loading.remove(endpoint); if let value = value { cache[endpoint] = value }; lock.unlock()
            if let done = completion { DispatchQueue.main.async { done(value) } }
        }
    }

    /// Blocking read with the one-time merge of the old two-item layout.
    private static func read(_ endpoint: String) -> CloudCredentials? {
        guard let text = CloudEditorSettings.secret(endpoint), let (credentials, legacy) = CloudCredentials.decode(text) else { return nil }
        guard legacy else { return credentials }
        var merged = credentials
        if let headersText = CloudEditorSettings.secret(endpoint + "#headers"),
           let object = try? JSONSerialization.jsonObject(with: Data(headersText.utf8)) as? [String: Any] {
            merged.headers = object.compactMapValues { $0 as? String }
        }
        // Writing is allowed without a prompt; the old headers item is left in
        // place (deleting it could prompt) and is never read again.
        try? CloudEditorSettings.setSecret(merged.encoded(), account: endpoint)
        return merged
    }

    /// Replace the key and/or headers. A nil field keeps the stored value, which
    /// needs one read; this runs in the background and reports on the main thread.
    static func update(_ endpoint: String, key: String?, headers: [String: String]?, completion: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let existing = (key == nil || headers == nil) ? (cached(endpoint) ?? read(endpoint)) : nil
            let value = CloudCredentials(key: key ?? existing?.key ?? "", headers: headers ?? existing?.headers ?? [:])
            var failure: Error?
            if value.key.isEmpty { failure = VoiceError.message("请输入 API Key 后保存") }
            else {
                do {
                    try CloudEditorSettings.setSecret(value.encoded(), account: endpoint)
                    lock.lock(); cache[endpoint] = value; lock.unlock()
                } catch { failure = error }
            }
            DispatchQueue.main.async { completion(failure) }
        }
    }
}

