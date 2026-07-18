/** Repository, branch, and file-content endpoints backed by the facade. */

import type { GitFileReference, GitRepositoryReference } from "@git-pont/core";
import { bytesToUtf8, isGitPontError } from "@git-pont/core";
import type { Env } from "../env.js";
import { buildUserGitPont, githubInstance } from "../gitpont.js";
import { errorResponse, json } from "../http.js";
import { ProfileStore } from "../stores/profile-store.js";
import type { ResolvedSession } from "../session.js";

function repositoryReference(namespace: string, name: string): GitRepositoryReference {
  return { instance: githubInstance, namespace, name };
}

/** GET /repositories — list repositories for the session's connection. */
export async function listRepositories(env: Env, session: ResolvedSession): Promise<Response> {
  const { gitPont } = buildUserGitPont(env, session.record.userId);
  const connectionId = session.record.connectionIds[0];
  if (!connectionId) return errorResponse(400, "Session has no connection");
  return guard(async () => {
    const repos = await gitPont.repositories(connectionId);
    return json({ items: repos.items, truncated: repos.truncated });
  });
}

/** GET /repos/:owner/:repo */
export async function getRepository(
  env: Env,
  session: ResolvedSession,
  owner: string,
  repo: string,
): Promise<Response> {
  const { gitPont } = buildUserGitPont(env, session.record.userId);
  return guard(async () => {
    const repository = await gitPont.repository(repositoryReference(owner, repo));
    // Record the repo in the user's recents (fire-and-forget semantics).
    await new ProfileStore(env.PROFILES).touchRecentRepo(session.record.userId, {
      instanceId: githubInstance.id,
      namespace: owner,
      name: repo,
    });
    return json(repository);
  });
}

/** GET /repos/:owner/:repo/branches */
export async function listBranches(
  env: Env,
  session: ResolvedSession,
  owner: string,
  repo: string,
): Promise<Response> {
  const { gitPont } = buildUserGitPont(env, session.record.userId);
  return guard(async () => {
    const branches = await gitPont.branches(repositoryReference(owner, repo));
    return json({ items: branches.items, truncated: branches.truncated });
  });
}

/**
 * GET /repos/:owner/:repo/contents/:path?ref=branch
 * Returns a directory listing or a single file (with UTF-8 text when decodable).
 */
export async function getContents(
  env: Env,
  session: ResolvedSession,
  owner: string,
  repo: string,
  path: string,
  ref: string | null,
): Promise<Response> {
  const { gitPont } = buildUserGitPont(env, session.record.userId);
  return guard(async () => {
    const repository = repositoryReference(owner, repo);
    const branch = ref ?? repository.defaultBranch ?? (await defaultBranch(gitPont, repository));
    const reference: GitFileReference = { repository, path, ref: branch };

    // Try a directory listing first; fall back to a single file read.
    try {
      const dir = await gitPont.listDirectory(reference);
      return json({ type: "directory", ref: branch, entries: dir.items });
    } catch (error) {
      if (!(isGitPontError(error) && (error.code === "unsupportedCapability" || error.code === "invalidProviderResponse"))) {
        throw error;
      }
    }

    const file = await gitPont.readFile(reference);
    return json({
      type: "file",
      ref: branch,
      path: file.reference.path,
      size: file.size,
      version: file.version,
      text: tryDecodeUtf8(file.content),
      contentBase64: base64(file.content),
    });
  });
}

async function defaultBranch(
  gitPont: ReturnType<typeof buildUserGitPont>["gitPont"],
  repository: GitRepositoryReference,
): Promise<string> {
  const repo = await gitPont.repository(repository);
  return repo.reference.defaultBranch ?? "main";
}

function tryDecodeUtf8(bytes: Uint8Array): string | undefined {
  // A NUL byte is a strong signal the content is binary, not text.
  if (bytes.includes(0)) return undefined;
  try {
    return bytesToUtf8(bytes);
  } catch {
    return undefined;
  }
}

function base64(bytes: Uint8Array): string {
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

async function guard(fn: () => Promise<Response>): Promise<Response> {
  try {
    return await fn();
  } catch (error) {
    if (isGitPontError(error)) {
      return errorResponse(statusForCode(error.code), error.message, error.code);
    }
    return errorResponse(500, "Unexpected error");
  }
}

function statusForCode(code: string): number {
  switch (code) {
    case "authenticationRequired":
    case "authenticationFailed":
      return 401;
    case "permissionDenied":
      return 403;
    case "notFound":
      return 404;
    case "conflict":
      return 409;
    case "rateLimited":
      return 429;
    case "missingConnection":
    case "ambiguousConnection":
      return 400;
    case "providerUnavailable":
      return 502;
    default:
      return 400;
  }
}
