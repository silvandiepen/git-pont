/**
 * Provider-neutral OAuth models. Mirrors the Swift OAuth types in
 * `docs/content/architecture.md` (Authentication Protocols).
 */

import type { GitAuthMethod, GitProviderInstance } from "./models.js";

/**
 * OAuth application configuration. GitPont ships no default client IDs — each
 * consuming app registers its own OAuth apps and injects the config.
 *
 * `clientSecret` should only be used for backend-mediated flows (e.g. the
 * Cloudflare Worker), never in native apps.
 */
export interface OAuthAppConfig {
  clientID: string;
  clientSecret?: string;
  redirectURI?: string;
  scopes: string[];
}

export interface GitOAuthStartRequest {
  instance: GitProviderInstance;
  method: GitAuthMethod;
  appConfig: OAuthAppConfig;
}

export interface GitOAuthBrowserSession {
  kind: "browser";
  authorizationURL: string;
  state: string;
  codeVerifier?: string;
  redirectURI: string;
}

export interface GitOAuthDeviceSession {
  kind: "device";
  verificationURI: string;
  userCode: string;
  deviceCode: string;
  /** Poll interval in seconds. */
  interval: number;
  expiresAt: Date;
}

export type GitOAuthStartResult = GitOAuthBrowserSession | GitOAuthDeviceSession;

export interface GitOAuthCompletionRequest {
  instance: GitProviderInstance;
  method: GitAuthMethod;
  appConfig: OAuthAppConfig;
  /** Full callback URL for browser/PKCE flows. */
  callbackURL?: string;
  state?: string;
  codeVerifier?: string;
  /** Device code for device flow. */
  deviceCode?: string;
}
