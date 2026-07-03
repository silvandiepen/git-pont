import Foundation
import GitPontCore

/// Environment and argument prefix for invoking system git with provider credentials.
public struct GitCLICredentialContext: Hashable, Sendable {
    public var argumentsPrefix: [String]
    public var environment: [String: String]

    public init(argumentsPrefix: [String], environment: [String: String]) {
        self.argumentsPrefix = argumentsPrefix
        self.environment = environment
    }
}

public extension GitPont {
    func gitCredentialContext(
        forRemoteURL url: URL,
        preferredConnectionID: String? = nil
    ) async throws -> GitCLICredentialContext {
        let instance = try await gitPontInstance(forRemoteURL: url)
        let connection = try await connection(for: instance, preferredConnectionID: preferredConnectionID)
        guard let credential = try await credential(for: connection.id) else {
            throw GitPontError.authenticationRequired
        }
        let username: String
        switch connection.instance.kind {
        case .github:
            username = "x-access-token"
        case .gitLabCloud, .gitLabSelfHosted:
            username = connection.authMethod == .personalAccessToken ? connection.accountLogin : "oauth2"
        case .forgejo, .gitea:
            username = connection.accountLogin.isEmpty ? "git-pont" : connection.accountLogin
        }
        let helper = "!f() { printf \"username=%s\\npassword=%s\\n\" \"$GITPONT_USERNAME\" \"$GITPONT_TOKEN\"; }; f"
        return GitCLICredentialContext(
            argumentsPrefix: ["-c", "credential.helper=\(helper)"],
            environment: [
                "GITPONT_USERNAME": username,
                "GITPONT_TOKEN": credential.accessToken,
                "GIT_TERMINAL_PROMPT": "0"
            ]
        )
    }

    private func gitPontInstance(forRemoteURL url: URL) async throws -> GitProviderInstance {
        guard let host = url.host?.lowercased() else {
            throw GitPontError.unsupportedURL(url.absoluteString)
        }
        switch host {
        case "github.com":
            return .github
        case "gitlab.com":
            return .gitLabCloud
        case "codeberg.org":
            return .codeberg
        default:
            let matches = try await connections().filter { $0.instance.baseURL.host?.lowercased() == host }
            guard let instance = matches.first?.instance else {
                throw GitPontError.unsupportedCapability("No configured provider instance for \(host)")
            }
            return instance
        }
    }
}
