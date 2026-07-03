import Foundation

/// Provider-neutral errors surfaced by git-pont.
public enum GitPontError: Error, Sendable {
    case unsupportedURL(String)
    case ambiguousURL(candidates: [GitURLReference])
    case missingConnection(GitProviderKind)
    case ambiguousConnection(instanceID: String, candidates: [GitConnection])
    case authenticationRequired
    case authenticationFailed(String)
    case permissionDenied(String)
    case notFound(String)
    case conflict(GitConflict)
    case fileTooLarge(size: Int?, limit: Int)
    case rateLimited(retryAfter: TimeInterval?)
    case providerUnavailable(String)
    case unsupportedCapability(String)
    case invalidProviderResponse(String)
    case partialSubmission(completed: GitChangeResult, failure: String)
}

/// Conflict details for a failed file write or delete.
public struct GitConflict: Hashable, Sendable {
    public var reference: GitFileReference
    public var expectedVersion: GitRemoteVersion?
    public var remoteVersion: GitRemoteVersion?
    public var providerMessage: String?

    public init(reference: GitFileReference, expectedVersion: GitRemoteVersion? = nil, remoteVersion: GitRemoteVersion? = nil, providerMessage: String? = nil) {
        self.reference = reference
        self.expectedVersion = expectedVersion
        self.remoteVersion = remoteVersion
        self.providerMessage = providerMessage
    }
}
