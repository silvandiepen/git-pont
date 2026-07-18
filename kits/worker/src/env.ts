/** Cloudflare bindings and configuration available to the worker. */
export interface Env {
  // KV namespaces
  SESSIONS: KVNamespace;
  CONNECTIONS: KVNamespace;
  PROFILES: KVNamespace;

  // Vars (wrangler.toml [vars])
  ALLOWED_ORIGINS: string;
  APP_LOGIN_REDIRECT: string;
  OAUTH_REDIRECT_BASE: string;
  GITHUB_SCOPES: string;
  SESSION_TTL_SECONDS: string;

  // Secrets (wrangler secret put / .dev.vars)
  GITHUB_CLIENT_ID: string;
  GITHUB_CLIENT_SECRET: string;
  GITPONT_ENC_KEY: string;
}

export function allowedOrigins(env: Env): string[] {
  return env.ALLOWED_ORIGINS.split(",")
    .map((origin) => origin.trim())
    .filter((origin) => origin.length > 0);
}

export function sessionTTLSeconds(env: Env): number {
  const parsed = Number(env.SESSION_TTL_SECONDS);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 2_592_000;
}

export function githubScopes(env: Env): string[] {
  return env.GITHUB_SCOPES.split(/[, ]/)
    .map((scope) => scope.trim())
    .filter((scope) => scope.length > 0);
}
