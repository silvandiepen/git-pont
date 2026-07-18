# @git-pont/core

Provider-neutral git-platform integration for TypeScript — the **auth + REST
proxy** layer of git-pont. A faithful port of the Swift contract
(`libs/swift`), it connects apps to GitHub (and, as they are ported,
GitLab/Forgejo/Gitea/Bitbucket) behind one facade, without each app
reimplementing authentication, URL parsing, repository APIs, commits, and pull
request workflows.

Framework-agnostic: depends only on the global `fetch` and WebCrypto, so it runs
unchanged in Cloudflare Workers, Node 18+, and browsers. It talks to provider
REST APIs — it does not shell out to `git` and does not clone.

## Install

Within this monorepo it is an npm workspace (`@git-pont/core`). It has no runtime
dependencies.

## Usage

```ts
import {
  GitPont,
  GitHubProvider,
  FetchHttpClient,
  InMemoryConnectionStore,
  InMemoryCredentialStore,
} from "@git-pont/core";

const gitPont = new GitPont({
  providers: [
    new GitHubProvider(new FetchHttpClient(), {
      clientID: "...",
      clientSecret: "...", // backend-mediated flows only
      redirectURI: "https://your-worker/auth/github/callback",
      scopes: ["repo", "read:user"],
    }),
  ],
  connectionStore: new InMemoryConnectionStore(),
  credentialStore: new InMemoryCredentialStore(),
});

// OAuth (web flow)
const start = await gitPont.startOAuth({ instance: GitProviderInstances.github, method: "oauthPKCE", appConfig });
// ...redirect the user to start.authorizationURL, then on callback:
const credential = await gitPont.completeOAuth({ instance, method: "oauthPKCE", appConfig, callbackURL });
const connection = await gitPont.addConnection(instance, credential, "oauthPKCE");

// Read
const repos = await gitPont.repositories(connection.id);
const file = await gitPont.openFile("https://github.com/owner/repo");
```

## What it provides

- Provider-neutral models and a `GitPont` facade matching the Swift API.
- Connection/credential resolution with proactive, race-free token refresh.
- Two-phase URL parsing with slashed-branch ambiguity resolution.
- Change submission strategies: direct commit, branch + PR, fork + PR, automatic.
- Injectable `HttpClient`, `ConnectionStore`, `CredentialStore`.
- Complete GitHub provider; scaffolded GitLab / Forgejo-Gitea / Bitbucket.

## Scripts

```sh
npm run build   # tsc (strict) -> dist
npm run test    # vitest
```

See [docs/content/typescript-kit.md](../../docs/content/typescript-kit.md) for
the full contract notes.
