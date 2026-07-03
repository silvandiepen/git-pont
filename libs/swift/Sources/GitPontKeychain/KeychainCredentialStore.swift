import Foundation
import GitPontCore
import Security

/// Apple Keychain-backed credential store.
public actor KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String = "git-pont") {
        self.service = service
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
        var loadQuery = query(for: connectionID)
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
        if status == errSecItemNotFound {
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

    private func query(for connectionID: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account(for: connectionID)
        ]
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
