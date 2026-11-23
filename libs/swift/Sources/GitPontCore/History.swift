import Foundation

// Commit history, a commit's changes, and the list of open change requests — what a git
// client shows, read through the provider's API instead of a local clone.

public extension GitProviderCapabilities {
    /// List the commits of a ref (optionally for one path) and read one commit's changes.
    static let commitHistory = GitProviderCapabilities(rawValue: 1 << 15)
    /// List pull requests or merge requests of a repository.
    static let pullRequestList = GitProviderCapabilities(rawValue: 1 << 16)
}

/// One commit as a history list shows it.
public struct GitCommitSummary: Hashable, Sendable, Codable, Identifiable {
    public var sha: String
    /// The whole message: subject line, then the body.
    public var message: String
    public var authorName: String
    public var authorEmail: String?
    public var authoredAt: Date?
    public var parentSHAs: [String]
    public var webURL: URL?

    public var id: String { sha }
    public var shortSHA: String { String(sha.prefix(7)) }

    /// The first line of the message.
    public var subject: String {
        message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? message
    }

    /// Everything after the subject line and the blank line that follows it.
    public var body: String {
        let parts = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return "" }
        return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isMerge: Bool { parentSHAs.count > 1 }

    public init(sha: String, message: String, authorName: String, authorEmail: String? = nil, authoredAt: Date? = nil, parentSHAs: [String] = [], webURL: URL? = nil) {
        self.sha = sha
        self.message = message
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authoredAt = authoredAt
        self.parentSHAs = parentSHAs
        self.webURL = webURL
    }
}

/// What a commit did to one file.
public enum GitCommitFileStatus: String, Hashable, Sendable, Codable {
    case added, modified, removed, renamed, copied, unknown
}

/// One file of a commit: its change, and the change as unified-diff hunks.
public struct GitCommitFileChange: Hashable, Sendable, Codable, Identifiable {
    public var path: String
    /// The path before a rename or copy.
    public var previousPath: String?
    public var status: GitCommitFileStatus
    public var additions: Int
    public var deletions: Int
    /// The hunks, each starting with its `@@ … @@` line, as `git diff` prints them after the
    /// file header. `nil` for a binary file, or when the provider leaves a large patch out.
    public var patch: String?
    public var isBinary: Bool

    public var id: String { previousPath.map { "\($0)->\(path)" } ?? path }

    public init(path: String, previousPath: String? = nil, status: GitCommitFileStatus, additions: Int = 0, deletions: Int = 0, patch: String? = nil, isBinary: Bool = false) {
        self.path = path
        self.previousPath = previousPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.patch = patch
        self.isBinary = isBinary
    }
}

/// A commit with every file it changed.
public struct GitCommitDetail: Hashable, Sendable, Codable {
    public var summary: GitCommitSummary
    public var files: [GitCommitFileChange]
    /// The provider sent fewer files than the commit changed.
    public var filesTruncated: Bool

    public init(summary: GitCommitSummary, files: [GitCommitFileChange], filesTruncated: Bool = false) {
        self.summary = summary
        self.files = files
        self.filesTruncated = filesTruncated
    }
}

/// Which commits to list: newest first, one page at a time.
public struct GitCommitHistoryQuery: Sendable {
    public var repository: GitRepositoryReference
    /// A branch, tag or commit. `nil`: the default branch.
    public var ref: String?
    /// Only commits that changed this path.
    public var path: String?
    /// 1-based.
    public var page: Int
    public var perPage: Int

    public init(repository: GitRepositoryReference, ref: String? = nil, path: String? = nil, page: Int = 1, perPage: Int = 30) {
        self.repository = repository
        self.ref = ref
        self.path = path
        self.page = max(1, page)
        self.perPage = min(100, max(1, perPage))
    }
}

/// The state a listed change request is in.
public enum GitPullRequestState: String, Hashable, Sendable, Codable {
    case open, closed, merged
}

/// Which change requests to list.
public struct GitPullRequestListQuery: Sendable {
    public enum Filter: String, Sendable { case open, closed, all }

    public var repository: GitRepositoryReference
    public var filter: Filter
    /// 1-based.
    public var page: Int
    public var perPage: Int

    public init(repository: GitRepositoryReference, filter: Filter = .open, page: Int = 1, perPage: Int = 30) {
        self.repository = repository
        self.filter = filter
        self.page = max(1, page)
        self.perPage = min(100, max(1, perPage))
    }
}

/// Reads `git diff` text — what Forgejo, Gitea and Bitbucket answer for a commit's diff — into
/// files, and counts the lines a patch adds and removes.
public enum GitUnifiedDiff {
    /// One entry per `diff --git` section.
    public static func files(fromGitDiff text: String) -> [GitCommitFileChange] {
        var files: [GitCommitFileChange] = []
        var current: Section?

        func flush() {
            guard let section = current else { return }
            files.append(section.change)
            current = nil
        }

        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git ") {
                flush()
                current = Section(header: line)
                continue
            }
            guard current != nil else { continue }
            if current!.hunks.isEmpty, !line.hasPrefix("@@") {
                current!.read(headerLine: line)
            } else if !line.isEmpty || !current!.hunks.isEmpty {
                current!.hunks.append(line)
            }
        }
        flush()
        return files
    }

    /// Lines added and removed by hunks text (the part from the first `@@`).
    public static func lineCounts(of patch: String) -> (additions: Int, deletions: Int) {
        var additions = 0
        var deletions = 0
        for line in patch.components(separatedBy: "\n") {
            if line.hasPrefix("+") { additions += 1 } else if line.hasPrefix("-") { deletions += 1 }
        }
        return (additions, deletions)
    }

    private struct Section {
        var oldPath: String?
        var newPath: String?
        var status: GitCommitFileStatus = .modified
        var isBinary = false
        var hunks: [String] = []

        init(header: String) {
            // "diff --git a/x b/y": a fallback; the ---/+++ and rename lines are more exact.
            let rest = header.dropFirst("diff --git ".count)
            if let split = rest.range(of: " b/") {
                oldPath = String(rest[..<split.lowerBound]).gitPontDroppingPrefix("a/")
                newPath = String(rest[split.upperBound...])
            }
        }

        mutating func read(headerLine line: String) {
            if line.hasPrefix("new file mode") {
                status = .added
            } else if line.hasPrefix("deleted file mode") {
                status = .removed
            } else if line.hasPrefix("rename from ") {
                status = .renamed
                oldPath = String(line.dropFirst("rename from ".count))
            } else if line.hasPrefix("rename to ") {
                status = .renamed
                newPath = String(line.dropFirst("rename to ".count))
            } else if line.hasPrefix("copy from ") {
                status = .copied
                oldPath = String(line.dropFirst("copy from ".count))
            } else if line.hasPrefix("copy to ") {
                newPath = String(line.dropFirst("copy to ".count))
            } else if line.hasPrefix("Binary files") || line.hasPrefix("GIT binary patch") {
                isBinary = true
            } else if line.hasPrefix("--- ") {
                let path = String(line.dropFirst(4))
                if path != "/dev/null" { oldPath = path.gitPontDroppingPrefix("a/") }
            } else if line.hasPrefix("+++ ") {
                let path = String(line.dropFirst(4))
                if path != "/dev/null" { newPath = path.gitPontDroppingPrefix("b/") }
            }
        }

        var change: GitCommitFileChange {
            // Drop the empty string after the text's final newline.
            var lines = hunks
            while lines.last == "" { lines.removeLast() }
            let patch = lines.isEmpty ? nil : lines.joined(separator: "\n") + "\n"
            let counts = patch.map(GitUnifiedDiff.lineCounts(of:)) ?? (additions: 0, deletions: 0)
            let path = (status == .removed ? oldPath : newPath) ?? oldPath ?? ""
            return GitCommitFileChange(
                path: path,
                previousPath: (status == .renamed || status == .copied) ? oldPath : nil,
                status: status,
                additions: counts.additions,
                deletions: counts.deletions,
                patch: isBinary ? nil : patch,
                isBinary: isBinary)
        }
    }
}

private extension String {
    func gitPontDroppingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
