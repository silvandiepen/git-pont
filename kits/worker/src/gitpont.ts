/**
 * Constructs per-user GitPont instances backed by the worker's KV stores, plus
 * the GitHub OAuth app config derived from the environment.
 */

import {
  FetchHttpClient,
  GitHubProvider,
  GitPont,
  GitProviderInstances,
  type GitAccount,
  type GitCredential,
  type OAuthAppConfig,
} from "@git-pont/core";
import { githubScopes, type Env } from "./env.js";
import { KVConnectionStore } from "./stores/connection-store.js";
import { KVCredentialStore } from "./stores/credential-store.js";

export const githubInstance = GitProviderInstances.github;

export function githubOAuthConfig(env: Env): OAuthAppConfig {
  return {
    clientID: env.GITHUB_CLIENT_ID,
    clientSecret: env.GITHUB_CLIENT_SECRET,
    redirectURI: `${env.OAUTH_REDIRECT_BASE.replace(/\/$/, "")}/auth/github/callback`,
    scopes: githubScopes(env),
  };
}

export interface UserGitPont {
  gitPont: GitPont;
  connectionStore: KVConnectionStore;
  credentialStore: KVCredentialStore;
}

/** Build a GitPont instance whose stores are scoped to a single user. */
export function buildUserGitPont(env: Env, userId: string): UserGitPont {
  const http = new FetchHttpClient();
  const provider = new GitHubProvider(http, githubOAuthConfig(env));
  const connectionStore = new KVConnectionStore(env.CONNECTIONS, userId);
  const credentialStore = new KVCredentialStore(env.CONNECTIONS, userId, env.GITPONT_ENC_KEY);
  const gitPont = new GitPont({
    providers: [provider],
    connectionStore,
    credentialStore,
  });
  return { gitPont, connectionStore, credentialStore };
}

/**
 * A GitPont instance with no persisted user, used only for OAuth start/complete
 * before a session exists. Stores are unused by those calls.
 */
export function buildAnonymousGitPont(env: Env): GitPont {
  return buildUserGitPont(env, "__anonymous__").gitPont;
}

/** Load the GitHub account for a freshly-obtained credential. */
export function githubAccount(env: Env, credential: GitCredential): Promise<GitAccount> {
  const provider = new GitHubProvider(new FetchHttpClient(), githubOAuthConfig(env));
  return provider.account(githubInstance, credential);
}

/** Stable per-user id derived from the provider account. */
export function githubUserId(account: GitAccount): string {
  return `github:${account.id}`;
}
