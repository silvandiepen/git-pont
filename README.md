# git-pont

`git-pont` is a provider-agnostic integration layer for hosted Git platforms. It connects apps to GitHub, GitLab, self-hosted GitLab, Forgejo, Gitea, and Codeberg without each app reimplementing authentication, URL parsing, repository APIs, commits, and pull request workflows.

The core contract is platform-neutral. The first implementation kit is Apple-focused and shipped as a Swift Package, but the provider model, URL parsing rules, authentication concepts, errors, and acceptance criteria should remain portable to future Android, web, or backend kits.

The library is content-agnostic. Lezin may use it for Markdown documents, but `git-pont` must work for any file content.

## Goals

- Connect accounts for supported Git platforms.
- Store and resolve provider credentials through an injected secure credential store.
- Persist connection metadata through an injected connection store.
- Parse provider URLs into normalized references, including ambiguous refs (branch names with slashes).
- Read repository files and list directories.
- Create, update, and delete files through provider APIs with conflict protection by default.
- Create branches, repositories, and forks.
- Create pull requests or merge requests, including cross-fork PRs.
- Submit a change end-to-end (direct commit, branch + PR, or fork + PR) as one operation.
- List repositories and branches with pagination handled internally.
- Provide Git CLI credentials for apps that shell out to `git`, such as GitFolder.
- Support self-hosted instances where the provider API is compatible.

## Non-Goals

- Do not become a full Git client.
- Do not own app-specific settings UI.
- Do not assume files are Markdown.
- Do not clone repositories.
- Do not implement conflict resolution UI.
- Do not require SSH in v1.
- Do not depend on Lezin or GitFolder.

## Kit Strategy

v1 ships the Swift library first:

- `libs/swift`, implemented as a Swift Package for Apple platforms.
- Native Apple credential storage through Keychain in a separate module.
- Native Apple consumers first: Lezin and GitFolder.

Future libraries may mirror the same contract for other platforms:

- Android/Kotlin.
- Web/TypeScript.
- Server/TypeScript or another backend runtime.

Future libraries must preserve the shared concepts documented in [Architecture](docs/content/architecture.md) and [Provider Model](docs/content/provider-model.md): provider instances, repository/file references, conflict-safe writes, two-phase URL parsing, pagination behavior, normalized errors, credential-store separation, and provider-neutral change submission.

Do not add Android or web implementation work to v1. The v1 goal is to design the Swift library so the shared contract can be reused later.

## Monorepo Layout

```txt
libs/
  swift/                 Reusable Swift Package for Apple platforms
  typescript/            @git-pont/core — TypeScript port of the contract (auth + REST proxy)
kits/
  worker/                @git-pont/worker — Cloudflare Worker consuming @git-pont/core
docs/
  content/               Portable Markdown documentation
  site/                  Static docs site builder and Girk-compatible config
scripts/
  validate-local.sh      Local validation entrypoint
```

`libs/typescript` is a framework-agnostic TypeScript library (fetch + WebCrypto)
that mirrors the Swift contract and runs in Workers, Node, and browsers.
`kits/worker` is a deployable Cloudflare Worker that adds multi-platform OAuth,
sessions, and persistence — the backend for web consumers such as gitKanban. See
[TypeScript Core Kit](docs/content/typescript-kit.md) and
[Cloudflare Worker Service](docs/content/worker-service.md).

Root commands:

```sh
npm run swift:build
npm run swift:test
npm run docs:build
npm run validate

npm run ts:build          # build @git-pont/core
npm run ts:test           # test @git-pont/core
npm run worker:typecheck  # typecheck @git-pont/worker
npm run worker:dev        # run the worker locally (wrangler dev)
npm run worker:deploy     # deploy the worker (wrangler deploy)
```

The Swift library can also be built directly:

```sh
swift build
swift test
swift build --package-path libs/swift
swift test --package-path libs/swift
```

The root `Package.swift` is the public SwiftPM entry point for external consumers. `libs/swift/Package.swift` remains as the library-local manifest for focused development inside the monorepo.

Live provider smoke tests are included but disabled unless credentials are present in the environment:

```sh
GITPONT_LIVE_GITHUB_TOKEN=... swift test --package-path libs/swift --filter LiveIntegrationTests
GITPONT_LIVE_GITLAB_TOKEN=... swift test --package-path libs/swift --filter LiveIntegrationTests
GITPONT_LIVE_FORGEJO_TOKEN=... swift test --package-path libs/swift --filter LiveIntegrationTests
```

Disposable live write tests are also included. They are disabled unless both a token and a dedicated write repository are configured. Each run creates a temporary branch, creates/reads/deletes one file under `.git-pont-live/`, and deletes the temporary branch.

```sh
GITPONT_LIVE_GITHUB_TOKEN=... GITPONT_LIVE_GITHUB_WRITE_REPO=owner/repo swift test --package-path libs/swift --filter githubDisposableWriteCycleWhenConfigured
GITPONT_LIVE_GITLAB_TOKEN=... GITPONT_LIVE_GITLAB_WRITE_REPO=namespace/project swift test --package-path libs/swift --filter gitLabDisposableWriteCycleWhenConfigured
GITPONT_LIVE_FORGEJO_TOKEN=... GITPONT_LIVE_FORGEJO_WRITE_REPO=owner/repo swift test --package-path libs/swift --filter forgeDisposableWriteCycleWhenConfigured
```

Use `GITPONT_LIVE_*_WRITE_BASE_REF` when the disposable repository's base branch is not `main`.

For a release-gate run across all configured live providers:

```sh
npm run validate:live
```

## Swift Package Shape

The Swift library is a Swift Package with these modules:

```txt
GitPontCore
GitPontGitHub
GitPontGitLab
GitPontForge
GitPontKeychain
GitPontGitCLI
```

`GitPontCore` contains the `GitPont` facade, all shared protocols, models, errors, URL parsing contracts, request abstractions, a `URLSessionHTTPClient`, test fixtures, and provider registry types.

`GitPontGitHub` implements GitHub and GitHub Enterprise-compatible behavior where reasonable.

`GitPontGitLab` implements GitLab.com and self-hosted GitLab.

`GitPontForge` implements Forgejo and Gitea. Codeberg is a preset Forgejo instance, not a separate provider kind.

`GitPontBitbucket` implements Bitbucket Cloud.

`GitPontKeychain` provides an Apple-platform credential store implementation.

`GitPontGitCLI` provides provider-neutral credential helper/environment output for apps that use the system `git` command.

`GitPontCore` does not depend on `GitPontGitCLI`; macOS apps that need system Git credentials import the Git CLI module to get the `gitCredentialContext` extension.

## Supported Providers

v1 supports:

- GitHub
- GitLab.com
- Self-hosted GitLab
- Forgejo custom instance
- Gitea custom instance
- Codeberg (preset Forgejo instance)
- Bitbucket Cloud

## Primary Consumers

### Lezin

Lezin opens and saves remote files directly through provider APIs.

```swift
let file = try await gitPont.openFile(from: url)

// Direct commit when the user can push:
let result = try await gitPont.commitFile(
    file.reference,
    content: Data(markdown.utf8),
    message: "Update document",
    expectedVersion: file.version
)

// Or let git-pont pick commit vs branch+PR vs fork+PR:
let change = GitFileChange(
    reference: file.reference,
    content: Data(markdown.utf8),
    message: "Update document",
    targetBranch: file.reference.ref,
    expectedVersion: file.version
)
let submitted = try await gitPont.submitChange(
    GitChangeSubmission(
        change: change,
        strategy: .automatic(
            branchName: "lezin/update-document",
            title: "Update document",
            body: nil,
            draft: false
        )
    )
)
```

Lezin does not need GitFolder and should not shell out to Git.

### GitFolder

GitFolder syncs local folders through the system `git` command. It should use `git-pont` for account connections, repository selection and creation, branch listing, URL normalization, and Git CLI credential injection.

```swift
let context = try await gitPont.gitCredentialContext(
    forRemoteURL: folder.repoURL,
    preferredConnectionID: folder.connectionID
)
let result = try gitRunner.run(
    context.argumentsPrefix + ["push", "-u", "origin", folder.branch],
    environment: context.environment
)
```

GitFolder remains the owner of folder scheduling, security-scoped folder bookmarks, snapshot commits, pull/rebase/push behavior, and user-facing sync state.

## Documentation

Markdown docs live in `docs/content`. The static docs site lives in `docs/site` and builds to `docs/site/dist`.

The site config is `docs/site/girk.json`. I could not verify a public Girk.dev schema, so this config uses intentionally simple fields (`contentDir`, `outputDir`, `navigation`) and the local builder consumes the same file.

- [Docs Index](docs/content/index.md)
- [Implementation Brief](docs/content/implementation-brief.md)
- [Kits and Platforms](docs/content/kits-and-platforms.md)
- [Architecture](docs/content/architecture.md)
- [Provider Model](docs/content/provider-model.md)
- [Authentication](docs/content/authentication.md)
- [TypeScript Core Kit](docs/content/typescript-kit.md)
- [Cloudflare Worker Service](docs/content/worker-service.md)
- [Provider APIs](docs/content/provider-apis.md)
- [Security](docs/content/security.md)
- [Git CLI Credentials](docs/content/git-cli-credentials.md)
- [Testing Strategy](docs/content/testing.md)
- [Implementation Plan](docs/content/implementation-plan.md)
- [Lezin Integration](docs/content/lezin-integration.md)
- [GitFolder Integration](docs/content/gitfolder-integration.md)
- [Acceptance Criteria](docs/content/acceptance-criteria.md)
- [Decisions](docs/content/decisions.md)
