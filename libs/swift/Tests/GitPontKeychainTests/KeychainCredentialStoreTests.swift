import Foundation
import GitPontCore
@testable import GitPontKeychain
import Testing

@Suite("KeychainCredentialStore")
struct KeychainCredentialStoreTests {
    @Test func credentialsRoundTripThroughCodablePayload() throws {
        let credential = GitCredential(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            tokenType: "Bearer",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            scopes: ["repo", "read:user"]
        )

        let data = try JSONEncoder().encode(credential)
        let decoded = try JSONDecoder().decode(GitCredential.self, from: data)

        #expect(decoded == credential)
    }

    @Test func liveKeychainCanSaveLoadUpdateAndDeleteCredentialWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["GITPONT_RUN_KEYCHAIN_TESTS"] == "1" else {
            return
        }

        let store = KeychainCredentialStore(service: "git-pont-tests-\(UUID().uuidString)")
        let connectionID = UUID().uuidString
        let original = GitCredential(accessToken: "original", refreshToken: "refresh", tokenType: "Bearer", scopes: ["repo"])
        let updated = GitCredential(accessToken: "updated", scopes: ["repo", "workflow"])

        try await store.save(original, for: connectionID)
        #expect(try await store.loadCredential(for: connectionID) == original)

        try await store.save(updated, for: connectionID)
        #expect(try await store.loadCredential(for: connectionID) == updated)

        try await store.deleteCredential(for: connectionID)
        #expect(try await store.loadCredential(for: connectionID) == nil)
    }
}
