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

    /// The request payload for the worker, or nil when the cloud editor is off or incomplete.
    func payload() -> [String: Any]? {
        guard enabled, !baseURL.isEmpty, !model.isEmpty, let key = Self.secret(baseURL), !key.isEmpty else { return nil }
        var value: [String: Any] = ["protocol": protocolName, "base_url": baseURL, "model": model, "api_key": key, "timeout_seconds": timeout]
        if let text = Self.secret(baseURL + "#headers"), let headers = try? JSONSerialization.jsonObject(with: Data(text.utf8)) { value["headers"] = headers }
        return value
    }

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
