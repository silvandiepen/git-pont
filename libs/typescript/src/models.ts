/**
 * Provider-neutral data models.
 *
 * These mirror the canonical Swift contract in
 * `libs/swift/Sources/GitPontCore/Models.swift`. Field names and semantics are
 * kept identical so the Swift and TypeScript kits stay in lockstep.
 */

/** Supported provider families. */
export type GitProviderKind =
  | "github"
  | "gitLabCloud"
  | "gitLabSelfHosted"
  | "forgejo"
  | "gitea"
  | "bitbucketCloud";

/** A concrete provider host and API endpoint. */
export interface GitProviderInstance {
  id: string;
  kind: GitProviderKind;
  /** Web base URL, e.g. `https://github.com`. */
  baseURL: string;
  /** API base URL, e.g. `https://api.github.com`. */
  apiBaseURL: string;
  displayName: string;
}

function trimTrailingSlash(value: string): string {
  return value.endsWith("/") ? value.replace(/\/+$/, "") : value;
}

/** Known public provider instances and factories for self-hosted ones. */
export const GitProviderInstances = {
  github: {
    id: "github.com",
    kind: "github",
    baseURL: "https://github.com",
    apiBaseURL: "https://api.github.com",
    displayName: "GitHub",
  } satisfies GitProviderInstance,

  gitLabCloud: {
    id: "gitlab.com",
    kind: "gitLabCloud",
    baseURL: "https://gitlab.com",
    apiBaseURL: "https://gitlab.com/api/v4",
    displayName: "GitLab.com",
  } satisfies GitProviderInstance,

  codeberg: {
    id: "codeberg.org",
    kind: "forgejo",
    baseURL: "https://codeberg.org",
    apiBaseURL: "https://codeberg.org/api/v1",
    displayName: "Codeberg",
  } satisfies GitProviderInstance,

  bitbucketCloud: {
    id: "bitbucket.org",
    kind: "bitbucketCloud",
    baseURL: "https://bitbucket.org",
    apiBaseURL: "https://api.bitbucket.org/2.0",
    displayName: "Bitbucket",
  } satisfies GitProviderInstance,

  gitLabSelfHosted(baseURL: string, displayName?: string): GitProviderInstance {
    const normalized = trimTrailingSlash(baseURL);
    return {
      id: normalized,
      kind: "gitLabSelfHosted",
      baseURL: normalized,
      apiBaseURL: `${normalized}/api/v4`,
      displayName: displayName ?? hostOf(normalized) ?? "GitLab",
    };
  },

  forgejo(baseURL: string, displayName?: string): GitProviderInstance {
    return forgeInstance("forgejo", baseURL, displayName);
  },

  gitea(baseURL: string, displayName?: string): GitProviderInstance {
    return forgeInstance("gitea", baseURL, displayName);
  },
};

function forgeInstance(
  kind: GitProviderKind,
  baseURL: string,
  displayName?: string,
): GitProviderInstance {
  const normalized = trimTrailingSlash(baseURL);
  return {
    id: normalized,
    kind,
    baseURL: normalized,
    apiBaseURL: `${normalized}/api/v1`,
    displayName: displayName ?? hostOf(normalized) ?? "Forge",
  };
}

function hostOf(value: string): string | undefined {
  try {
    return new URL(value).host;
  } catch {
    return undefined;
  }
}

/** Current provider account metadata. */
export interface GitAccount {
  id: string;
  login: string;
  displayName?: string;
  avatarURL?: string;
  email?: string;
}

/** Authentication method used by a connection. */
export type GitAuthMethod = "oauthDevice" | "oauthPKCE" | "personalAccessToken";

/** Stored connection metadata without secrets. */
export interface GitConnection {
  id: string;
  instance: GitProviderInstance;
  accountID: string;
  accountLogin: string;
  displayName?: string;
  authMethod: GitAuthMethod;
  createdAt: Date;
  updatedAt: Date;
}

/**
 * Provider credential. Contains secrets — never persist to plain config or log.
 */
export interface GitCredential {
  accessToken: string;
  refreshToken?: string;
  tokenType?: string;
  expiresAt?: Date;
  scopes: string[];
}

/** Stable reference to a repository on a provider instance. */
export interface GitRepositoryReference {
  instance: GitProviderInstance;
  namespace: string;
  name: string;
  defaultBranch?: string;
  webURL?: string;
  cloneHTTPSURL?: string;
}

/** Normalized repository permissions for the connected account. */
export interface GitRepositoryPermissions {
  canRead: boolean;
  canPush: boolean;
  canAdmin: boolean;
}

/** Repository metadata including permissions used for submission strategy. */
export interface GitRepository {
  reference: GitRepositoryReference;
  description?: string;
  isPrivate: boolean;
  isFork: boolean;
  parent?: GitRepositoryReference;
  permissions: GitRepositoryPermissions;
  updatedAt?: Date;
}

/** Branch metadata. */
export interface GitBranch {
  name: string;
  commitSHA: string;
  isDefault: boolean;
  isProtected: boolean;
}

/** Reference to a file path at a repository ref. */
export interface GitFileReference {
  repository: GitRepositoryReference;
  path: string;
  ref: string;
  webURL?: string;
}

/** Parsed URL reference before or after branch ambiguity resolution. */
export interface GitURLReference {
  instance: GitProviderInstance;
  namespace: string;
  name: string;
  ref?: string;
  path?: string;
}

/** Result of provider URL parsing. */
export type GitURLParseResult =
  | { kind: "resolved"; reference: GitURLReference }
  | { kind: "ambiguous"; candidates: GitURLReference[] };

/** Normalized file content encoding. */
export type GitFileEncoding = "utf8" | "binary";

/** Provider-specific remote version identity for conflict detection. */
export type GitRemoteVersion =
  | { kind: "blobSHA"; sha: string }
  | { kind: "commitID"; id: string }
  | { kind: "opaque"; provider: GitProviderKind; value: string };

export const GitRemoteVersion = {
  blobSHA(sha: string): GitRemoteVersion {
    return { kind: "blobSHA", sha };
  },
  commitID(id: string): GitRemoteVersion {
    return { kind: "commitID", id };
  },
  opaque(provider: GitProviderKind, value: string): GitRemoteVersion {
    return { kind: "opaque", provider, value };
  },
};

/** Remote file payload and version metadata. Content is raw bytes. */
export interface GitRemoteFile {
  reference: GitFileReference;
  content: Uint8Array;
  encoding: GitFileEncoding;
  version?: GitRemoteVersion;
  size?: number;
  lastCommitID?: string;
  etag?: string;
}

/** Directory entry kind. */
export type GitDirectoryEntryType = "file" | "directory" | "symlink" | "submodule";

/** Directory listing entry. */
export interface GitDirectoryEntry {
  name: string;
  path: string;
  type: GitDirectoryEntryType;
  size?: number;
}

/** Request to create or update a repository file. */
export interface GitFileChange {
  reference: GitFileReference;
  content: Uint8Array;
  message: string;
  targetBranch: string;
  baseBranch?: string;
  expectedVersion?: GitRemoteVersion;
  allowBlindOverwrite?: boolean;
  authorName?: string;
  authorEmail?: string;
}

/** Request to delete a repository file. */
export interface GitFileDeleteRequest {
  reference: GitFileReference;
  message: string;
  targetBranch: string;
  expectedVersion?: GitRemoteVersion;
  allowBlindOverwrite?: boolean;
  authorName?: string;
  authorEmail?: string;
}

/** Result of a file commit or delete. */
export interface GitCommitResult {
  commitSHA: string;
  branch: string;
  newVersion?: GitRemoteVersion;
  webURL?: string;
}

/** Request to create a branch from an existing ref. */
export interface GitCreateBranchRequest {
  repository: GitRepositoryReference;
  name: string;
  fromRef: string;
}

/** Request to delete a branch ref. */
export interface GitDeleteBranchRequest {
  repository: GitRepositoryReference;
  name: string;
}

/** Request to create a repository. */
export interface GitCreateRepositoryRequest {
  name: string;
  namespace?: string;
  description?: string;
  isPrivate?: boolean;
  initializeWithReadme?: boolean;
}

/** Request to create a pull request or merge request. */
export interface GitPullRequestRequest {
  repository: GitRepositoryReference;
  title: string;
  body?: string;
  sourceBranch: string;
  sourceRepository?: GitRepositoryReference;
  targetBranch: string;
  draft?: boolean;
}

/** Query for an existing open pull request or merge request. */
export interface GitPullRequestQuery {
  repository: GitRepositoryReference;
  sourceBranch: string;
  sourceRepository?: GitRepositoryReference;
  targetBranch: string;
}

/** Provider-neutral pull request or merge request result. */
export interface GitPullRequest {
  id: string;
  number?: number;
  title: string;
  webURL: string;
  sourceBranch: string;
  targetBranch: string;
  providerName: string;
}

/** Strategy used by the facade to submit a change. */
export type GitChangeStrategy =
  | { kind: "directCommit" }
  | { kind: "existingBranch"; branchName: string }
  | {
      kind: "branchAndPullRequest";
      branchName: string;
      title: string;
      body?: string;
      draft?: boolean;
    }
  | {
      kind: "forkAndPullRequest";
      branchName: string;
      title: string;
      body?: string;
      draft?: boolean;
    }
  | {
      kind: "automatic";
      branchName: string;
      title: string;
      body?: string;
      draft?: boolean;
    };

/** High-level change submission request handled by the facade. */
export interface GitChangeSubmission {
  change: GitFileChange;
  strategy: GitChangeStrategy;
}

/** Result of a high-level change submission. */
export interface GitChangeResult {
  commit: GitCommitResult;
  pullRequest?: GitPullRequest;
  /** The fork when forking was used, otherwise the original repository. */
  usedRepository: GitRepositoryReference;
  usedBranch: string;
}

/** List response with truncation metadata. Callers never see page tokens. */
export interface GitList<Element> {
  items: Element[];
  truncated: boolean;
}

/** Capability flags advertised by a provider implementation. */
export interface GitProviderCapabilities {
  publicFileRead: boolean;
  authenticatedFileRead: boolean;
  fileCommit: boolean;
  fileDelete: boolean;
  batchCommit: boolean;
  directoryList: boolean;
  branchCreate: boolean;
  branchDelete: boolean;
  repositoryCreate: boolean;
  repositoryFork: boolean;
  pullRequestCreate: boolean;
  gitCLICredentials: boolean;
}

export function noCapabilities(): GitProviderCapabilities {
  return {
    publicFileRead: false,
    authenticatedFileRead: false,
    fileCommit: false,
    fileDelete: false,
    batchCommit: false,
    directoryList: false,
    branchCreate: false,
    branchDelete: false,
    repositoryCreate: false,
    repositoryFork: false,
    pullRequestCreate: false,
    gitCLICredentials: false,
  };
}

/** Provider-specific wording for change request objects. */
export type GitChangeRequestTerm = "pullRequest" | "mergeRequest";

/** File-level conflict detail returned when a write collides with the remote. */
export interface GitConflict {
  reference: GitFileReference;
  expectedVersion?: GitRemoteVersion;
  remoteVersion?: GitRemoteVersion;
  providerMessage?: string;
}
