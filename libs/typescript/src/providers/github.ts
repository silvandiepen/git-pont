/**
 * GitHub provider implementation for GitHub.com.
 *
 * Port of `libs/swift/Sources/GitPontGitHub/GitHubProvider.swift`, extended with
 * the OAuth authorization-code (web) flow needed by backend-mediated consumers
 * such as the Cloudflare Worker. Device flow and PAT auth are preserved.
 */

import { GitPontError } from "../errors.js";
import {
  appendQuery,
  base64ToBytes,
  bytesToBase64,
  formEncode,
  nextLinkURL,
  utf8ToBytes,
  type HttpClient,
  type HttpResponse,
} from "../http.js";
import {
  GitProviderInstances,
  GitRemoteVersion,
  type GitAccount,
  type GitAuthMethod,
  type GitBranch,
  type GitChangeRequestTerm,
  type GitCommitResult,
  type GitCreateBranchRequest,
  type GitCreateRepositoryRequest,
  type GitCredential,
  type GitDeleteBranchRequest,
  type GitDirectoryEntry,
  type GitDirectoryEntryType,
  type GitFileChange,
  type GitFileDeleteRequest,
  type GitFileReference,
  type GitList,
  type GitProviderCapabilities,
  type GitProviderInstance,
  type GitProviderKind,
  type GitPullRequest,
  type GitPullRequestQuery,
  type GitPullRequestRequest,
  type GitRemoteFile,
  type GitRepository,
  type GitRepositoryReference,
  type GitURLParseResult,
} from "../models.js";
import type {
  GitOAuthCompletionRequest,
  GitOAuthStartRequest,
  GitOAuthStartResult,
  OAuthAppConfig,
} from "../oauth.js";
import type {
  GitAuthenticationProvider,
  GitProvider,
  GitProviderRequestContext,
} from "../protocols.js";
import { isHexRef, parseRefPath, pathSegments, stripGitSuffix } from "../url.js";

const USER_AGENT = "git-pont";
const GITHUB = GitProviderInstances.github;

export class GitHubProvider implements GitProvider, GitAuthenticationProvider {
  readonly kind: GitProviderKind = "github";
  readonly displayName = "GitHub";
  readonly changeRequestTerm: GitChangeRequestTerm = "pullRequest";
  readonly capabilities: GitProviderCapabilities = {
    publicFileRead: true,
    authenticatedFileRead: true,
    fileCommit: true,
    fileDelete: true,
    batchCommit: false,
    directoryList: true,
    branchCreate: true,
    branchDelete: true,
    repositoryCreate: true,
    repositoryFork: true,
    pullRequestCreate: true,
    gitCLICredentials: true,
  };

  private readonly http: HttpClient;
  private readonly oauth?: OAuthAppConfig;

  constructor(http: HttpClient, oauth?: OAuthAppConfig) {
    this.http = http;
    this.oauth = oauth;
  }

  canHandle(url: string): boolean {
    const host = safeHost(url);
    return host === "github.com" || host === "raw.githubusercontent.com";
  }

  parse(url: string): GitURLParseResult {
    const host = safeHost(url);
    const segments = pathSegments(url);
    if (host === "github.com" && segments.length >= 2) {
      const namespace = segments[0]!;
      const name = segments[1]!;
      if (segments.length === 2) {
        return {
          kind: "resolved",
          reference: { instance: GITHUB, namespace, name: stripGitSuffix(name) },
        };
      }
      if (segments.length >= 5 && (segments[2] === "blob" || segments[2] === "tree")) {
        return parseRefPath(GITHUB, namespace, name, segments.slice(3));
      }
    }
    if (host === "raw.githubusercontent.com" && segments.length >= 4) {
      return parseRefPath(GITHUB, segments[0]!, segments[1]!, segments.slice(2));
    }
    throw GitPontError.unsupportedURL(url);
  }

  // MARK: - Authentication

  authorizationHeaders(credential: GitCredential, _authMethod: GitAuthMethod): Record<string, string> {
    return { Authorization: `Bearer ${credential.accessToken}` };
  }

  async startOAuth(request: GitOAuthStartRequest): Promise<GitOAuthStartResult> {
    const config = this.oauth ?? request.appConfig;
    if (request.method === "oauthDevice") {
      const response = await this.sendOAuthJSON<GitHubDeviceCodeResponse>({
        method: "POST",
        url: `${GITHUB.baseURL}/login/device/code`,
        headers: oauthHeaders(),
        body: formEncode({
          client_id: config.clientID,
          scope: config.scopes.join(" "),
        }),
      });
      return {
        kind: "device",
        verificationURI: response.verification_uri,
        userCode: response.user_code,
        deviceCode: response.device_code,
        interval: response.interval ?? 5,
        expiresAt: new Date(Date.now() + response.expires_in * 1000),
      };
    }

    // Authorization-code (web) flow — used by the worker. GitHub OAuth Apps
    // authenticate the token exchange with a client secret rather than PKCE.
    const state = randomToken(24);
    const redirectURI = config.redirectURI;
    if (!redirectURI) {
      throw GitPontError.authenticationFailed("GitHub web OAuth requires a redirectURI in the app config");
    }
    const authorizationURL = appendQuery(`${GITHUB.baseURL}/login/oauth/authorize`, {
      client_id: config.clientID,
      redirect_uri: redirectURI,
      scope: config.scopes.join(" "),
      state,
      response_type: "code",
    });
    return { kind: "browser", authorizationURL, state, redirectURI };
  }

  async completeOAuth(request: GitOAuthCompletionRequest): Promise<GitCredential> {
    const config = this.oauth ?? request.appConfig;
    if (request.method === "oauthDevice") {
      if (!request.deviceCode) {
        throw GitPontError.authenticationFailed("GitHub OAuth device code is required");
      }
      const response = await this.sendOAuthJSON<GitHubOAuthTokenResponse>({
        method: "POST",
        url: `${GITHUB.baseURL}/login/oauth/access_token`,
        headers: oauthHeaders(),
        body: formEncode({
          client_id: config.clientID,
          device_code: request.deviceCode,
          grant_type: "urn:ietf:params:oauth:grant-type:device_code",
        }),
      });
      return credentialFromToken(response);
    }

    // Web flow: exchange the authorization code from the callback URL.
    const code = extractCode(request.callbackURL);
    if (!code) {
      throw GitPontError.authenticationFailed("GitHub OAuth callback is missing an authorization code");
    }
    const payload: Record<string, string> = {
      client_id: config.clientID,
      code,
      grant_type: "authorization_code",
    };
    if (config.clientSecret) payload.client_secret = config.clientSecret;
    if (config.redirectURI) payload.redirect_uri = config.redirectURI;
    const response = await this.sendOAuthJSON<GitHubOAuthTokenResponse>({
      method: "POST",
      url: `${GITHUB.baseURL}/login/oauth/access_token`,
      headers: oauthHeaders(),
      body: formEncode(payload),
    });
    return credentialFromToken(response);
  }

  async refreshCredential(
    credential: GitCredential,
    _instance: GitProviderInstance,
  ): Promise<GitCredential> {
    if (!credential.refreshToken) return credential;
    const config = this.oauth ?? { clientID: "", scopes: credential.scopes };
    if (!config.clientID) {
      throw GitPontError.unsupportedCapability("GitHub OAuth refresh requires an OAuth client ID");
    }
    const payload: Record<string, string> = {
      client_id: config.clientID,
      refresh_token: credential.refreshToken,
      grant_type: "refresh_token",
    };
    if (config.clientSecret) payload.client_secret = config.clientSecret;
    const response = await this.sendOAuthJSON<GitHubOAuthTokenResponse>({
      method: "POST",
      url: `${GITHUB.baseURL}/login/oauth/access_token`,
      headers: oauthHeaders(),
      body: formEncode(payload),
    });
    return credentialFromToken(response);
  }

  // MARK: - Account, repositories, branches

  async account(instance: GitProviderInstance, credential: GitCredential): Promise<GitAccount> {
    const dto = await this.sendJSON<GitHubUserDTO>({
      method: "GET",
      url: `${instance.apiBaseURL}/user`,
      headers: {
        ...this.authorizationHeaders(credential, "personalAccessToken"),
        Accept: "application/vnd.github+json",
        "User-Agent": USER_AGENT,
      },
    });
    return {
      id: String(dto.id),
      login: dto.login,
      displayName: dto.name ?? undefined,
      avatarURL: dto.avatar_url ?? undefined,
      email: dto.email ?? undefined,
    };
  }

  async repositories(context: GitProviderRequestContext): Promise<GitList<GitRepository>> {
    requireCredential(context);
    const repos = await this.paginatedJSON<GitHubRepositoryDTO>(
      appendQuery(`${GITHUB.apiBaseURL}/user/repos`, { per_page: "100", sort: "updated" }),
      this.headers(context),
    );
    return { items: repos.map((r) => mapRepository(r, GITHUB)), truncated: repos.length >= 3000 };
  }

  async repository(
    reference: GitRepositoryReference,
    context: GitProviderRequestContext,
  ): Promise<GitRepository> {
    const dto = await this.sendJSON<GitHubRepositoryDTO>({
      method: "GET",
      url: `${GITHUB.apiBaseURL}/repos/${enc(reference.namespace)}/${enc(reference.name)}`,
      headers: this.headers(context),
    });
    return mapRepository(dto, reference.instance);
  }

  async branches(
    repository: GitRepositoryReference,
    context: GitProviderRequestContext,
  ): Promise<GitList<GitBranch>> {
    const url = appendQuery(
      `${GITHUB.apiBaseURL}/repos/${enc(repository.namespace)}/${enc(repository.name)}/branches`,
      { per_page: "100" },
    );
    const branches = await this.paginatedJSON<GitHubBranchDTO>(url, this.headers(context));
    return {
      items: branches.map((b) => ({
        name: b.name,
        commitSHA: b.commit.sha,
        isDefault: false,
        isProtected: b.protected ?? false,
      })),
      truncated: branches.length >= 3000,
    };
  }

  // MARK: - Files

  async readFile(
    reference: GitFileReference,
    context: GitProviderRequestContext,
  ): Promise<GitRemoteFile> {
    const dto = await this.sendJSON<GitHubContentDTO>({
      method: "GET",
      url: appendQuery(this.contentsURL(reference.repository, reference.path), { ref: reference.ref }),
      headers: this.headers(context),
    });
    if (dto.type !== "file") {
      throw GitPontError.unsupportedCapability("GitHub content is not a file");
    }
    if (dto.size !== undefined && dto.size > 100_000_000) {
      throw GitPontError.fileTooLarge(dto.size, 100_000_000);
    }
    if (dto.encoding !== "base64" || dto.content === undefined) {
      throw GitPontError.fileTooLarge(dto.size, 100_000_000);
    }
    let bytes: Uint8Array;
    try {
      bytes = base64ToBytes(dto.content);
    } catch {
      throw GitPontError.invalidProviderResponse("GitHub returned invalid Base64 content");
    }
    return {
      reference,
      content: bytes,
      encoding: "binary",
      version: dto.sha ? GitRemoteVersion.blobSHA(dto.sha) : undefined,
      size: dto.size,
    };
  }

  async listDirectory(
    reference: GitFileReference,
    context: GitProviderRequestContext,
  ): Promise<GitList<GitDirectoryEntry>> {
    const entries = await this.sendJSON<GitHubContentDTO[]>({
      method: "GET",
      url: appendQuery(this.contentsURL(reference.repository, reference.path), { ref: reference.ref }),
      headers: this.headers(context),
    });
    return { items: entries.map(mapDirectoryEntry), truncated: false };
  }

  async commitFile(
    change: GitFileChange,
    context: GitProviderRequestContext,
  ): Promise<GitCommitResult> {
    requireCredential(context);
    const identity = gitHubIdentity(change.authorName, change.authorEmail);
    const payload: Record<string, unknown> = {
      message: change.message,
      content: bytesToBase64(change.content),
      branch: change.targetBranch,
    };
    const sha = githubSHA(change.expectedVersion);
    if (sha) payload.sha = sha;
    if (identity) {
      payload.committer = identity;
      payload.author = identity;
    }
    let dto: GitHubContentWriteResponse;
    try {
      dto = await this.sendJSON<GitHubContentWriteResponse>({
        method: "PUT",
        url: this.contentsURL(change.reference.repository, change.reference.path),
        headers: this.headers(context),
        body: utf8ToBytes(JSON.stringify(payload)),
      });
    } catch (error) {
      throw populatedConflict(error, change.reference, change.expectedVersion);
    }
    return {
      commitSHA: dto.commit.sha,
      branch: change.targetBranch,
      newVersion: dto.content?.sha ? GitRemoteVersion.blobSHA(dto.content.sha) : undefined,
      webURL: dto.commit.html_url,
    };
  }

  async deleteFile(
    request: GitFileDeleteRequest,
    context: GitProviderRequestContext,
  ): Promise<GitCommitResult> {
    requireCredential(context);
    const sha = githubSHA(request.expectedVersion);
    if (!sha) {
      throw GitPontError.conflict({
        reference: request.reference,
        expectedVersion: request.expectedVersion,
        providerMessage: "GitHub deletes require a blob SHA",
      });
    }
    const identity = gitHubIdentity(request.authorName, request.authorEmail);
    const payload: Record<string, unknown> = {
      message: request.message,
      sha,
      branch: request.targetBranch,
    };
    if (identity) {
      payload.committer = identity;
      payload.author = identity;
    }
    let dto: GitHubContentWriteResponse;
    try {
      dto = await this.sendJSON<GitHubContentWriteResponse>({
        method: "DELETE",
        url: this.contentsURL(request.reference.repository, request.reference.path),
        headers: this.headers(context),
        body: utf8ToBytes(JSON.stringify(payload)),
      });
    } catch (error) {
      throw populatedConflict(error, request.reference, request.expectedVersion);
    }
    return { commitSHA: dto.commit.sha, branch: request.targetBranch, webURL: dto.commit.html_url };
  }

  // MARK: - Branches, repos, forks, PRs

  async createBranch(
    request: GitCreateBranchRequest,
    context: GitProviderRequestContext,
  ): Promise<GitBranch> {
    requireCredential(context);
    let sha: string;
    if (isHexRef(request.fromRef)) {
      sha = request.fromRef;
    } else {
      const ref = await this.sendJSON<GitHubRefDTO>({
        method: "GET",
        url: this.gitRefURL(request.repository, `heads/${request.fromRef}`),
        headers: this.headers(context),
      });
      sha = ref.object.sha;
    }
    const created = await this.sendJSON<GitHubRefDTO>({
      method: "POST",
      url: `${GITHUB.apiBaseURL}/repos/${enc(request.repository.namespace)}/${enc(request.repository.name)}/git/refs`,
      headers: this.headers(context),
      body: utf8ToBytes(JSON.stringify({ ref: `refs/heads/${request.name}`, sha })),
    });
    return { name: request.name, commitSHA: created.object.sha, isDefault: false, isProtected: false };
  }

  async deleteBranch(
    request: GitDeleteBranchRequest,
    context: GitProviderRequestContext,
  ): Promise<void> {
    requireCredential(context);
    const response = await this.http.send({
      method: "DELETE",
      url: this.gitRefURL(request.repository, `heads/${request.name}`),
      headers: this.headers(context),
    });
    validate(response);
  }

  async createRepository(
    request: GitCreateRepositoryRequest,
    context: GitProviderRequestContext,
  ): Promise<GitRepository> {
    requireCredential(context);
    const payload = {
      name: request.name,
      description: request.description,
      private: request.isPrivate ?? true,
      auto_init: request.initializeWithReadme ?? false,
    };
    const url = request.namespace
      ? `${GITHUB.apiBaseURL}/orgs/${enc(request.namespace)}/repos`
      : `${GITHUB.apiBaseURL}/user/repos`;
    const dto = await this.sendJSON<GitHubRepositoryDTO>({
      method: "POST",
      url,
      headers: this.headers(context),
      body: utf8ToBytes(JSON.stringify(payload)),
    });
    return mapRepository(dto, GITHUB);
  }

  async forkRepository(
    reference: GitRepositoryReference,
    context: GitProviderRequestContext,
  ): Promise<GitRepository> {
    const connection = requireConnection(context);
    const existing = await this.existingFork(reference, connection.accountLogin, context);
    if (existing) return existing;
    const dto = await this.sendJSON<GitHubRepositoryDTO>({
      method: "POST",
      url: `${GITHUB.apiBaseURL}/repos/${enc(reference.namespace)}/${enc(reference.name)}/forks`,
      headers: this.headers(context),
    });
    return this.confirmedRepository(mapRepository(dto, reference.instance).reference, context);
  }

  async createPullRequest(
    request: GitPullRequestRequest,
    context: GitProviderRequestContext,
  ): Promise<GitPullRequest> {
    requireCredential(context);
    const head = request.sourceRepository
      ? `${request.sourceRepository.namespace}:${request.sourceBranch}`
      : request.sourceBranch;
    const dto = await this.sendJSON<GitHubPullRequestDTO>({
      method: "POST",
      url: `${GITHUB.apiBaseURL}/repos/${enc(request.repository.namespace)}/${enc(request.repository.name)}/pulls`,
      headers: this.headers(context),
      body: utf8ToBytes(
        JSON.stringify({
          title: request.title,
          body: request.body,
          head,
          base: request.targetBranch,
          draft: request.draft ?? false,
        }),
      ),
    });
    return mapPullRequest(dto);
  }

  async findPullRequest(
    query: GitPullRequestQuery,
    context: GitProviderRequestContext,
  ): Promise<GitPullRequest | undefined> {
    requireCredential(context);
    const sourceNamespace = query.sourceRepository?.namespace ?? query.repository.namespace;
    const head = `${sourceNamespace}:${query.sourceBranch}`;
    const url = appendQuery(
      `${GITHUB.apiBaseURL}/repos/${enc(query.repository.namespace)}/${enc(query.repository.name)}/pulls`,
      { state: "open", head, base: query.targetBranch, per_page: "1" },
    );
    const dtos = await this.sendJSON<GitHubPullRequestDTO[]>({
      method: "GET",
      url,
      headers: this.headers(context),
    });
    const first = dtos[0];
    return first ? mapPullRequest(first) : undefined;
  }

  // MARK: - Helpers

  private headers(context: GitProviderRequestContext): Record<string, string> {
    const base: Record<string, string> = {
      Accept: "application/vnd.github+json",
      "User-Agent": USER_AGENT,
    };
    if (!context.credential) return base;
    return {
      ...this.authorizationHeaders(context.credential, context.connection?.authMethod ?? "personalAccessToken"),
      ...base,
    };
  }

  private contentsURL(repository: GitRepositoryReference, path: string): string {
    const encodedPath = path
      .split("/")
      .filter((s) => s.length > 0)
      .map((s) => enc(s))
      .join("/");
    return `${GITHUB.apiBaseURL}/repos/${enc(repository.namespace)}/${enc(repository.name)}/contents/${encodedPath}`;
  }

  private gitRefURL(repository: GitRepositoryReference, ref: string): string {
    return `${GITHUB.apiBaseURL}/repos/${enc(repository.namespace)}/${enc(repository.name)}/git/ref/${ref}`;
  }

  private async existingFork(
    reference: GitRepositoryReference,
    owner: string,
    context: GitProviderRequestContext,
  ): Promise<GitRepository | undefined> {
    const forks = await this.paginatedJSON<GitHubRepositoryDTO>(
      appendQuery(
        `${GITHUB.apiBaseURL}/repos/${enc(reference.namespace)}/${enc(reference.name)}/forks`,
        { per_page: "100" },
      ),
      this.headers(context),
    );
    return forks
      .map((r) => mapRepository(r, reference.instance))
      .find((r) => r.reference.namespace === owner && r.reference.name === reference.name);
  }

  private async confirmedRepository(
    reference: GitRepositoryReference,
    context: GitProviderRequestContext,
  ): Promise<GitRepository> {
    try {
      return await this.repository(reference, context);
    } catch (error) {
      if (error instanceof GitPontError && error.code === "notFound") {
        return {
          reference,
          isPrivate: false,
          isFork: true,
          permissions: { canRead: true, canPush: true, canAdmin: false },
        };
      }
      throw error;
    }
  }

  private async sendJSON<T>(request: {
    method: string;
    url: string;
    headers: Record<string, string>;
    body?: Uint8Array;
  }): Promise<T> {
    const response = await this.http.send(request);
    validate(response);
    try {
      return response.json<T>();
    } catch (error) {
      throw GitPontError.invalidProviderResponse(messageOf(error));
    }
  }

  private async paginatedJSON<T>(url: string, headers: Record<string, string>): Promise<T[]> {
    let nextURL: string | undefined = url;
    const items: T[] = [];
    let pages = 0;
    while (nextURL && pages < 30) {
      pages += 1;
      const response: HttpResponse = await this.http.send({ method: "GET", url: nextURL, headers });
      validate(response);
      try {
        items.push(...response.json<T[]>());
      } catch (error) {
        throw GitPontError.invalidProviderResponse(messageOf(error));
      }
      nextURL = nextLinkURL(response);
    }
    return items;
  }

  private async sendOAuthJSON<T>(request: {
    method: string;
    url: string;
    headers: Record<string, string>;
    body?: Uint8Array | string;
  }): Promise<T> {
    const response = await this.http.send(request);
    let parsed: unknown;
    try {
      parsed = response.json<unknown>();
    } catch {
      throw GitPontError.invalidProviderResponse("GitHub OAuth returned a non-JSON response");
    }
    if (isOAuthError(parsed)) {
      throw GitPontError.authenticationFailed(parsed.error_description ?? parsed.error);
    }
    validate(response);
    return parsed as T;
  }
}

// MARK: - DTOs and mapping

interface GitHubUserDTO {
  id: number;
  login: string;
  name?: string | null;
  avatar_url?: string | null;
  email?: string | null;
}

interface GitHubDeviceCodeResponse {
  device_code: string;
  user_code: string;
  verification_uri: string;
  expires_in: number;
  interval?: number;
}

interface GitHubOAuthTokenResponse {
  access_token: string;
  refresh_token?: string;
  token_type?: string;
  scope?: string;
  expires_in?: number;
}

interface GitHubOAuthErrorResponse {
  error: string;
  error_description?: string;
}

interface GitHubPermissionsDTO {
  pull?: boolean;
  push?: boolean;
  admin?: boolean;
}

interface GitHubRepositoryReferenceDTO {
  name: string;
  full_name: string;
  default_branch?: string;
  html_url?: string;
  clone_url?: string;
}

interface GitHubRepositoryDTO extends GitHubRepositoryReferenceDTO {
  description?: string | null;
  private: boolean;
  fork: boolean;
  permissions?: GitHubPermissionsDTO;
  parent?: GitHubRepositoryReferenceDTO;
  updated_at?: string;
}

interface GitHubBranchDTO {
  name: string;
  commit: { sha: string };
  protected?: boolean;
}

interface GitHubContentDTO {
  type: string;
  encoding?: string;
  size?: number;
  name: string;
  path: string;
  content?: string;
  sha?: string;
  html_url?: string;
}

interface GitHubContentWriteResponse {
  content?: GitHubContentDTO;
  commit: { sha: string; html_url?: string };
}

interface GitHubRefDTO {
  ref: string;
  object: { sha: string };
}

interface GitHubPullRequestDTO {
  id: number;
  number?: number;
  title: string;
  html_url: string;
  head: { ref: string };
  base: { ref: string };
}

function mapRepositoryReference(
  dto: GitHubRepositoryReferenceDTO,
  instance: GitProviderInstance,
): GitRepositoryReference {
  const [namespace, ...rest] = dto.full_name.split("/");
  return {
    instance,
    namespace: namespace ?? "",
    name: rest.length > 0 ? rest.join("/") : dto.name,
    defaultBranch: dto.default_branch,
    webURL: dto.html_url,
    cloneHTTPSURL: dto.clone_url,
  };
}

function mapRepository(dto: GitHubRepositoryDTO, instance: GitProviderInstance): GitRepository {
  return {
    reference: mapRepositoryReference(dto, instance),
    description: dto.description ?? undefined,
    isPrivate: dto.private,
    isFork: dto.fork,
    parent: dto.parent ? mapRepositoryReference(dto.parent, instance) : undefined,
    permissions: {
      canRead: dto.permissions?.pull ?? true,
      canPush: dto.permissions?.push ?? false,
      canAdmin: dto.permissions?.admin ?? false,
    },
    updatedAt: dto.updated_at ? new Date(dto.updated_at) : undefined,
  };
}

function mapDirectoryEntry(dto: GitHubContentDTO): GitDirectoryEntry {
  let type: GitDirectoryEntryType;
  switch (dto.type) {
    case "dir":
      type = "directory";
      break;
    case "symlink":
      type = "symlink";
      break;
    case "submodule":
      type = "submodule";
      break;
    default:
      type = "file";
  }
  return { name: dto.name, path: dto.path, type, size: dto.size };
}

function mapPullRequest(dto: GitHubPullRequestDTO): GitPullRequest {
  return {
    id: String(dto.id),
    number: dto.number,
    title: dto.title,
    webURL: dto.html_url,
    sourceBranch: dto.head.ref,
    targetBranch: dto.base.ref,
    providerName: "GitHub",
  };
}

function credentialFromToken(response: GitHubOAuthTokenResponse): GitCredential {
  return {
    accessToken: response.access_token,
    refreshToken: response.refresh_token,
    tokenType: response.token_type,
    expiresAt: response.expires_in ? new Date(Date.now() + response.expires_in * 1000) : undefined,
    scopes: parseScopes(response.scope),
  };
}

function parseScopes(scope: string | undefined): string[] {
  if (!scope) return [];
  return scope
    .split(/[, ]/)
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

function gitHubIdentity(
  name: string | undefined,
  email: string | undefined,
): { name: string; email: string } | undefined {
  if (!name || !email) return undefined;
  return { name, email };
}

function githubSHA(version: GitFileChange["expectedVersion"]): string | undefined {
  return version?.kind === "blobSHA" ? version.sha : undefined;
}

function oauthHeaders(): Record<string, string> {
  return {
    Accept: "application/json",
    "Content-Type": "application/x-www-form-urlencoded",
    "User-Agent": USER_AGENT,
  };
}

function isOAuthError(value: unknown): value is GitHubOAuthErrorResponse {
  return typeof value === "object" && value !== null && "error" in value && typeof (value as { error: unknown }).error === "string";
}

function populatedConflict(
  error: unknown,
  reference: GitFileReference,
  expectedVersion: GitFileChange["expectedVersion"],
): unknown {
  if (error instanceof GitPontError && error.code === "conflict" && error.data.conflict) {
    return GitPontError.conflict({
      reference,
      expectedVersion,
      remoteVersion: error.data.conflict.remoteVersion,
      providerMessage: error.data.conflict.providerMessage,
    });
  }
  return error;
}

function validate(response: HttpResponse): void {
  const status = response.statusCode;
  if (status >= 200 && status < 300) return;
  switch (status) {
    case 401:
      throw GitPontError.authenticationFailed("GitHub authentication failed");
    case 403:
      throw GitPontError.permissionDenied("GitHub permission denied");
    case 404:
      throw GitPontError.notFound("GitHub resource not found");
    case 409:
    case 422:
      throw GitPontError.conflict({
        reference: {
          repository: { instance: GITHUB, namespace: "", name: "" },
          path: "",
          ref: "",
        },
        providerMessage: "GitHub conflict",
      });
    case 429:
      throw GitPontError.rateLimited(retryAfterSeconds(response.header("Retry-After")));
    default:
      if (status >= 500 && status < 600) {
        throw GitPontError.providerUnavailable(`GitHub returned ${status}`);
      }
      throw GitPontError.invalidProviderResponse(`GitHub returned ${status}`);
  }
}

function retryAfterSeconds(value: string | undefined): number | undefined {
  if (!value) return undefined;
  const seconds = Number(value);
  return Number.isNaN(seconds) ? undefined : seconds;
}

function requireCredential(context: GitProviderRequestContext): GitCredential {
  if (!context.credential) throw GitPontError.authenticationRequired();
  return context.credential;
}

function requireConnection(context: GitProviderRequestContext): NonNullable<GitProviderRequestContext["connection"]> {
  requireCredential(context);
  if (!context.connection) throw GitPontError.authenticationRequired();
  return context.connection;
}

function extractCode(callbackURL: string | undefined): string | undefined {
  if (!callbackURL) return undefined;
  try {
    return new URL(callbackURL).searchParams.get("code") ?? undefined;
  } catch {
    return undefined;
  }
}

function safeHost(url: string): string | undefined {
  try {
    return new URL(url).host.toLowerCase();
  } catch {
    return undefined;
  }
}

function enc(segment: string): string {
  return encodeURIComponent(segment);
}

function randomToken(bytes: number): string {
  const buffer = new Uint8Array(bytes);
  globalThis.crypto.getRandomValues(buffer);
  return [...buffer].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
