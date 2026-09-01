import Foundation
import Security

/// 飞牛连接凭据（值类型，便于跨并发域传递）
struct Credentials: Sendable, Equatable {
    /// 服务器基址，如 `http://192.168.11.200:5666`
    var baseUrl: String = ""
    /// 登录令牌（`music-token`）
    var token: String = ""
    /// 是否走 FN Connect 中继链路
    var relayMode: Bool = false
    /// 安全码（服务器开启访问码防护时必填）
    var accessCode: String?
    /// FNID（本机上次成功探测用的 ID）
    var fnId: String = ""
    var username: String = ""
    /// 32 位 hex 设备 ID，登录时上报
    var deviceId: String = ""

    var isValid: Bool { !token.isEmpty && !baseUrl.isEmpty }

    /// 归一化基址：去掉用户可能输入的 `/music/api/v1` 后缀与末尾斜杠
    static func normalizeBaseUrl(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "/music/api/v1/*$", with: "", options: .regularExpression)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

// MARK: - 持久化

/// 凭据持久化：token / 安全码存 Keychain，其余（地址、FNID、用户名）存 UserDefaults
enum CredentialsStore {
    private enum Key {
        static let token = "niupod.token"
        static let accessCode = "niupod.accessCode"
        static let baseUrl = "niupod.baseUrl"
        static let relayMode = "niupod.relayMode"
        static let fnId = "niupod.fnId"
        static let username = "niupod.username"
        static let deviceId = "niupod.deviceId"
        static let password = "niupod.password"
        static let connectionOrder = "niupod.connectionOrder"
        static let disabledGroups = "niupod.disabledGroups"
    }

    private static let defaults = UserDefaults.standard

    static func load() -> Credentials {
        var c = Credentials()
        c.token = Keychain.read(Key.token) ?? ""
        c.accessCode = Keychain.read(Key.accessCode)
        c.baseUrl = defaults.string(forKey: Key.baseUrl) ?? ""
        c.relayMode = defaults.bool(forKey: Key.relayMode)
        c.fnId = defaults.string(forKey: Key.fnId) ?? ""
        c.username = defaults.string(forKey: Key.username) ?? ""
        c.deviceId = defaults.string(forKey: Key.deviceId) ?? ""
        return c
    }

    static func save(_ c: Credentials, password: String? = nil) {
        if c.token.isEmpty {
            Keychain.delete(Key.token)
        } else {
            Keychain.write(c.token, for: Key.token)
        }
        if let code = c.accessCode, !code.isEmpty {
            Keychain.write(code, for: Key.accessCode)
        } else {
            Keychain.delete(Key.accessCode)
        }
        defaults.set(c.baseUrl, forKey: Key.baseUrl)
        defaults.set(c.relayMode, forKey: Key.relayMode)
        defaults.set(c.fnId, forKey: Key.fnId)
        defaults.set(c.username, forKey: Key.username)
        defaults.set(c.deviceId, forKey: Key.deviceId)
        if let password, !password.isEmpty {
            Keychain.write(password, for: Key.password)
        }
    }

    /// 保存密码以便登录页自动填充与静默重登
    static func savePassword(_ password: String) {
        Keychain.write(password, for: Key.password)
    }

    static func loadPassword() -> String? {
        Keychain.read(Key.password)
    }

    /// 退出登录：清掉 token 与安全码，但保留地址/用户名便于重新登录时自动填充
    static func clearSession() {
        Keychain.delete(Key.token)
        Keychain.delete(Key.accessCode)
        Keychain.delete(Key.password)
        defaults.set(false, forKey: Key.relayMode)
    }

    static var connectionOrder: [ProbeCandidateGroup] {
        get {
            guard let raw = defaults.array(forKey: Key.connectionOrder) as? [String] else {
                return kDefaultConnectionOrder
            }
            let parsed = raw.compactMap(ProbeCandidateGroup.init(rawValue:))
            return parsed.isEmpty ? kDefaultConnectionOrder : parsed
        }
        set { defaults.set(newValue.map(\.rawValue), forKey: Key.connectionOrder) }
    }

    static var disabledGroups: Set<ProbeCandidateGroup> {
        get {
            guard let raw = defaults.array(forKey: Key.disabledGroups) as? [String] else { return [] }
            return Set(raw.compactMap(ProbeCandidateGroup.init(rawValue:)))
        }
        set { defaults.set(newValue.map(\.rawValue), forKey: Key.disabledGroups) }
    }

    static func resetAll() {
        for k in [Key.token, Key.accessCode, Key.password] { Keychain.delete(k) }
        for k in [Key.baseUrl, Key.relayMode, Key.fnId, Key.username, Key.deviceId,
                  Key.connectionOrder, Key.disabledGroups] {
            defaults.removeObject(forKey: k)
        }
    }
}

// MARK: - Keychain

enum Keychain {
    /// Keychain service 名跟随主 App 的 bundle ID。改动它会让老版本存的凭据读不到
    /// （用户需要重新登录一次），非必要不要动。
    private static let service = "com.niupod"

    @discardableResult
    static func write(_ value: String, for account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        delete(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
