import AppKit
import Security

/// Optional cloud models: one service (protocol, address, key, headers), a fast
/// model for dictation cleanup and translation, a strong model for rule tuning
/// and meeting writing, and a switch per feature. Settings live in
/// UserDefaults; the API key and any gateway headers live only in the Keychain.
struct CloudEditorSettings {
    static let service = "io.github.zacklinkk.freetalk.cleanup"
    static let protocols = [("openai", "OpenAI 兼容（/chat/completions）"), ("anthropic", "Anthropic 兼容（/v1/messages）")]
    static let timeouts: [Double] = [5, 8, 12, 20]
    /// Rule tuning and meeting writing run in the background; they may take minutes.
    static let strongTimeout: Double = 240

    /// Dictation cleanup uses the fast model (the original switch, kept for upgrades).
    var enabled = false
    var protocolName = "openai"
    var baseURL = ""
    /// The fast model.
    var model = ""
    /// Empty means the fast model does the strong model's work too.
    var strongModel = ""
    var timeout: Double = 8
    var translation = false
    var meetings = false
    var tuning = true

    static func load() -> Self {
        let d = UserDefaults.standard
        var s = Self()
        s.enabled = d.bool(forKey: "cloudCleanupEnabled")
        s.protocolName = protocols.map(\.0).contains(d.string(forKey: "cloudCleanupProtocol") ?? "") ? d.string(forKey: "cloudCleanupProtocol")! : "openai"
        s.baseURL = d.string(forKey: "cloudCleanupBaseURL") ?? ""
        s.model = d.string(forKey: "cloudCleanupModel") ?? ""
        // Before 0.7 the strong model was typed on the tuning card.
        s.strongModel = d.string(forKey: "cloudStrongModel") ?? d.string(forKey: "promptTuningModel") ?? ""
        let saved = d.double(forKey: "cloudCleanupTimeout")
        s.timeout = timeouts.contains(saved) ? saved : 8
        s.translation = d.bool(forKey: "cloudTranslationEnabled")
        s.meetings = d.bool(forKey: "cloudMeetingsEnabled")
        s.tuning = d.object(forKey: "cloudTuningEnabled") as? Bool ?? true
        return s
    }

    func save() {
        let d = UserDefaults.standard
        d.set(enabled, forKey: "cloudCleanupEnabled"); d.set(protocolName, forKey: "cloudCleanupProtocol")
        d.set(baseURL, forKey: "cloudCleanupBaseURL"); d.set(model, forKey: "cloudCleanupModel"); d.set(timeout, forKey: "cloudCleanupTimeout")
        d.set(strongModel, forKey: "cloudStrongModel"); d.set(translation, forKey: "cloudTranslationEnabled")
        d.set(meetings, forKey: "cloudMeetingsEnabled"); d.set(tuning, forKey: "cloudTuningEnabled")
    }

    /// The model that rule tuning and meeting writing use.
    var strongName: String { strongModel.isEmpty ? model : strongModel }
    /// Address, a model name and a stored key: enough to try either model.
    var serviceReady: Bool { !baseURL.isEmpty && !model.isEmpty && CloudCredentialStore.storedPresence(baseURL) == true }
    /// Any feature that sends text to the service is switched on.
    var anyFeature: Bool { enabled || translation || meetings || tuning || NightlySettings.load().active }
    /// Features that run without a click need the key read at launch; the
    /// others read it when the user starts them.
    var readsKeyAtLaunch: Bool { enabled || translation || NightlySettings.load().active }

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

    func payload(with credentials: CloudCredentials, strong: Bool = false) -> [String: Any] {
        var value: [String: Any] = ["protocol": protocolName, "base_url": baseURL, "model": strong ? strongName : model,
                                    "api_key": credentials.key, "timeout_seconds": strong ? Self.strongTimeout : timeout]
        if !credentials.headers.isEmpty { value["headers"] = credentials.headers }
        return value
    }

    /// Even an attribute query can wait behind an unrelated Keychain authorization.
    fileprivate static func queryStoredKey(_ account: String) -> OSStatus {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        return SecItemCopyMatching(query as CFDictionary, nil)
    }

    /// Complete enough to try: switched on, endpoint, model and a stored key.
    var configured: Bool { enabled && serviceReady }

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
        case "http_401": return "云端拒绝了 API Key"
        case "http_403": return "云端拒绝了请求（密钥无效或额度已用完）"
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
    private static var presence: [String: Bool] = [:]
    private static var loading: Set<String> = []
    private static var waiting: [String: [(CloudCredentials?) -> Void]] = [:]

    static func cached(_ endpoint: String) -> CloudCredentials? { lock.lock(); defer { lock.unlock() }; return cache[endpoint] }
    static func storedPresence(_ endpoint: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return cache[endpoint] != nil ? true : presence[endpoint]
    }

    /// UI and recording paths consult only memory. A locked or unavailable Keychain
    /// leaves the presence unknown, so it cannot be reported as a missing key.
    static func checkPresence(_ endpoint: String, completion: @escaping (Bool?) -> Void) {
        if cached(endpoint) != nil { DispatchQueue.main.async { completion(true) }; return }
        DispatchQueue.global(qos: .userInitiated).async {
            let status = CloudEditorSettings.queryStoredKey(endpoint)
            lock.lock()
            let present: Bool? = cache[endpoint] != nil || status == errSecSuccess ? true
                : status == errSecItemNotFound ? false : nil
            presence[endpoint] = present
            lock.unlock()
            DispatchQueue.main.async { completion(present) }
        }
    }
    static var isLoading: Bool { lock.lock(); defer { lock.unlock() }; return !loading.isEmpty }
    #if E2E_HOOKS
    /// The end-to-end checks hand over the key themselves: a test build would
    /// otherwise wait on a Keychain prompt that nobody answers.
    static func seed(_ endpoint: String, _ value: CloudCredentials) { lock.lock(); cache[endpoint] = value; lock.unlock() }
    #endif

    /// Start a background read unless one is running or the value is cached.
    /// Every caller's completion runs on the main thread, including callers
    /// that arrive while an earlier read is still waiting on a Keychain prompt.
    static func prefetch(_ endpoint: String, completion: ((CloudCredentials?) -> Void)? = nil) {
        lock.lock()
        if let value = cache[endpoint] { lock.unlock(); completion.map { done in DispatchQueue.main.async { done(value) } }; return }
        if let completion = completion { waiting[endpoint, default: []].append(completion) }
        let started = loading.insert(endpoint).inserted
        lock.unlock()
        guard started else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let value = read(endpoint)
            lock.lock(); loading.remove(endpoint); if let value = value { cache[endpoint] = value }
            let callers = waiting.removeValue(forKey: endpoint) ?? []
            lock.unlock()
            if !callers.isEmpty { DispatchQueue.main.async { callers.forEach { $0(value) } } }
        }
    }

    /// Blocking read with the one-time merge of the old two-item layout.
    private static func read(_ endpoint: String) -> CloudCredentials? {
        #if E2E_HOOKS
        // The test build never reads the Keychain: macOS would ask about a binary
        // nobody approved, possibly while nobody is at the Mac. The test seeds the key.
        if ProcessInfo.processInfo.environment["FREETALK_E2E_SUPPORT"] != nil { return nil }
        #endif
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

