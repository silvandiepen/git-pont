import Foundation

/// A provider access credential stored separately from connection metadata.
public struct GitCredential: Codable, Hashable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var tokenType: String?
    public var expiresAt: Date?
    public var scopes: [String]

    public init(accessToken: String, refreshToken: String? = nil, tokenType: String? = nil, expiresAt: Date? = nil, scopes: [String] = []) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.expiresAt = expiresAt
        self.scopes = scopes
    }
}

/// OAuth application configuration supplied by the consuming app.
public struct OAuthAppConfig: Sendable {
    public var clientID: String
    public var clientSecret: String?
    public var redirectURI: URL?
    public var scopes: [String]

    public init(clientID: String, clientSecret: String? = nil, redirectURI: URL? = nil, scopes: [String] = []) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
        self.scopes = scopes
    }
}

/// Request to begin a provider OAuth flow.
public struct GitOAuthStartRequest: Sendable {
    public var instance: GitProviderInstance
    public var method: GitAuthMethod
    public var appConfig: OAuthAppConfig

    public init(instance: GitProviderInstance, method: GitAuthMethod, appConfig: OAuthAppConfig) {
        self.instance = instance
        self.method = method
        self.appConfig = appConfig
    }
}

/// Provider-neutral result for an OAuth start request.
public enum GitOAuthStartResult: Sendable {
    case browser(GitOAuthBrowserSession)
    case device(GitOAuthDeviceSession)
}

/// Browser-based OAuth session data the app must persist until callback.
public struct GitOAuthBrowserSession: Sendable {
    public var authorizationURL: URL
    public var state: String
    public var codeVerifier: String?
    public var redirectURI: URL

    public init(authorizationURL: URL, state: String, codeVerifier: String? = nil, redirectURI: URL) {
        self.authorizationURL = authorizationURL
        self.state = state
        self.codeVerifier = codeVerifier
        self.redirectURI = redirectURI
    }
}

/// Device-flow OAuth session data the app shows and polls.
public struct GitOAuthDeviceSession: Sendable {
    public var verificationURI: URL
    public var userCode: String
    public var deviceCode: String
    public var interval: TimeInterval
    public var expiresAt: Date

    public init(verificationURI: URL, userCode: String, deviceCode: String, interval: TimeInterval, expiresAt: Date) {
        self.verificationURI = verificationURI
        self.userCode = userCode
        self.deviceCode = deviceCode
        self.interval = interval
        self.expiresAt = expiresAt
    }
}

/// Request to complete an OAuth flow after browser callback or device polling.
public struct GitOAuthCompletionRequest: Sendable {
    public var instance: GitProviderInstance
    public var method: GitAuthMethod
    public var appConfig: OAuthAppConfig
    public var callbackURL: URL?
    public var state: String?
    public var codeVerifier: String?
    public var deviceCode: String?

    public init(instance: GitProviderInstance, method: GitAuthMethod, appConfig: OAuthAppConfig, callbackURL: URL? = nil, state: String? = nil, codeVerifier: String? = nil, deviceCode: String? = nil) {
        self.instance = instance
        self.method = method
        self.appConfig = appConfig
        self.callbackURL = callbackURL
        self.state = state
        self.codeVerifier = codeVerifier
        self.deviceCode = deviceCode
    }
}
