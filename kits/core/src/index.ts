/**
 * @git-pont/core — provider-neutral git platform integration (auth + REST proxy).
 *
 * TypeScript port of the git-pont Swift contract. Framework-agnostic: depends
 * only on the global `fetch` and WebCrypto, so it runs unchanged in Cloudflare
 * Workers, Node 18+, and browsers.
 */

export * from "./models.js";
export * from "./errors.js";
export * from "./http.js";
export * from "./oauth.js";
export * from "./protocols.js";
export * from "./stores.js";
export * from "./url.js";
export * from "./git-pont.js";
export { GitHubProvider } from "./providers/github.js";
export { GitLabProvider, ForgeProvider, BitbucketProvider } from "./providers/scaffold.js";
