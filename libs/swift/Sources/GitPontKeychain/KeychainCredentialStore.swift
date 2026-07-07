import Foundation
import GitPontCore
import Security

/// Apple Keychain-backed credential store.
public actor KeychainCredentialStore: CredentialStore {
    private let service: String
    private let accessGroup: String?

    public init(service: String = "git-pont", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func save(_ credential: GitCredential, for connectionID: String) async throws {
        let data = try JSONEncoder().encode(credential)
        let baseQuery = query(for: connectionID)
        var addQuery = baseQuery
        addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecValueData] = data

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            try update(data, for: connectionID)
            return
        }
        try throwIfUnexpected(status)
    }

    public func loadCredential(for connectionID: String) async throws -> GitCredential? {
        if let credential = try loadCredential(for: connectionID, includeAccessGroup: true) {
            return credential
        }

        guard accessGroup != nil, let legacyCredential = try loadCredential(for: connectionID, includeAccessGroup: false) else {
            return nil
        }

        try await save(legacyCredential, for: connectionID)
        _ = SecItemDelete(query(for: connectionID, includeAccessGroup: false) as CFDictionary)
        return legacyCredential
    }

    private func loadCredential(for connectionID: String, includeAccessGroup: Bool) throws -> GitCredential? {
        var loadQuery = query(for: connectionID, includeAccessGroup: includeAccessGroup)
        loadQuery[kSecMatchLimit] = kSecMatchLimitOne
        loadQuery[kSecReturnData] = kCFBooleanTrue

        var result: CFTypeRef?
        let status = SecItemCopyMatching(loadQuery as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        try throwIfUnexpected(status)
        guard let data = result as? Data else {
            throw GitPontError.invalidProviderResponse("Keychain returned a credential without data")
        }
        return try JSONDecoder().decode(GitCredential.self, from: data)
    }

    public func deleteCredential(for connectionID: String) async throws {
        let status = SecItemDelete(query(for: connectionID) as CFDictionary)
        _ = SecItemDelete(query(for: connectionID, includeAccessGroup: false) as CFDictionary)
        if status == errSecItemNotFound || status == errSecSuccess {
            return
        }
        try throwIfUnexpected(status)
    }

    private func update(_ data: Data, for connectionID: String) throws {
        let status = SecItemUpdate(
            query(for: connectionID) as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        try throwIfUnexpected(status)
    }

    private func query(for connectionID: String, includeAccessGroup: Bool = true) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account(for: connectionID)
        ]
        if includeAccessGroup, let accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        return query
    }

    private func account(for connectionID: String) -> String {
        "git-pont:\(connectionID)"
    }

    private func throwIfUnexpected(_ status: OSStatus) throws {
        guard status != errSecSuccess else {
            return
        }
        throw GitPontError.providerUnavailable("Keychain operation failed with OSStatus \(status)")
    }
}
