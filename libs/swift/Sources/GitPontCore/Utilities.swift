import Foundation

/// Validation helpers for paths and write requests.
public enum GitPontValidator {
    public static func validate(change: GitFileChange) throws {
        try validateRepositoryPath(change.reference.path)
        try validateCommitMessage(change.message)
    }

    public static func validate(delete request: GitFileDeleteRequest) throws {
        try validateRepositoryPath(request.reference.path)
        try validateCommitMessage(request.message)
        if request.expectedVersion == nil && !request.allowBlindOverwrite {
            throw GitPontError.conflict(GitConflict(
                reference: request.reference,
                expectedVersion: nil,
                providerMessage: "Deleting without an expected version requires allowBlindOverwrite"
            ))
        }
    }

    public static func validateRepositoryPath(_ path: String) throws {
        if path.isEmpty || path.hasPrefix("/") {
            throw GitPontError.unsupportedURL("Invalid repository path")
        }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        if segments.contains("..") || segments.contains("") {
            throw GitPontError.unsupportedURL("Invalid repository path")
        }
        if path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) {
            throw GitPontError.unsupportedURL("Invalid repository path")
        }
    }

    public static func validateCommitMessage(_ message: String) throws {
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw GitPontError.unsupportedURL("Commit message must not be empty")
        }
    }
}

public extension URL {
    var gitPontDirectoryURL: URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        let url = components?.url ?? self
        let string = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: string) ?? url
    }

    var gitPontPathSegments: [String] {
        path.split(separator: "/").map(String.init)
    }
}
