# Decisions

Formerly "Open Questions". All of these are decided; the implementation agent should not revisit them.

## Kit Strategy

v1 is a Swift library implemented as a Swift Package for Apple platforms.

Reason:

- Lezin is native Apple.
- GitFolder is native macOS.
- Keychain and OAuth browser flows are Apple-native.

Future platform kits may mirror the same contract for Android, web, and backend use. Nothing in the provider model, error model, URL parsing rules, or authentication concepts may depend on Swift-only behavior that could not be represented in Kotlin, TypeScript, or another mainstream runtime.

The Swift library is the only implementation target for v1. Future libraries or kits must not expand the v1 definition of done.

## Repository Location

`/Users/silvandiepen/Repositories/_libs/git-pont`, as its own Git repository and internal monorepo.

The Swift library lives under `libs/swift`. Future reusable platform libraries should be added as siblings such as `libs/kotlin`, `libs/typescript`, or `libs/server`. The `kits/` namespace is reserved for app/demo kits if needed later. Shared documentation lives under `docs/content`; the docs site builder lives under `docs/site`.

## OAuth App Ownership

- Core supports injected `OAuthAppConfig` only; GitPont ships no default client IDs.
- Each consuming app (Lezin, GitFolder) registers and provides its own OAuth apps.
- PAT/token auth works without any OAuth app setup and is the guaranteed path for every provider.

## Codeberg

Codeberg is a preset Forgejo `GitProviderInstance`, not a `GitProviderKind`. There is exactly one Forgejo/Gitea code path in `GitPontForge`.

## Pull Requests vs Merge Requests

One capability (`pullRequestCreate`), one request/result type. Wording is a UI concern exposed via `GitProvider.changeRequestTerm`.

## Conflict Protection

Mandatory by default. Updating or deleting an existing file without an expected version requires `allowBlindOverwrite = true`. This is not configurable globally.

## Pagination

Handled inside providers; apps receive complete `GitList` results with a `truncated` flag, capped at 30 pages of 100 items. Exposed page tokens are a possible v2 addition, not v1.

## SSH

Not in v1, in any module. GitFolder's existing SSH mode stays app-owned.

## Naming

Use `GitPont` in Swift types, repository/package family name `git-pont`, and Apple product names like `GitPontCore`.

Use "library" for reusable implementation packages and "kit" only for app/demo bundles or composed starter integrations. Do not name future libraries or kits in code until they exist.

Avoid `GitBridge` in docs/code to prevent naming drift.

## Source of Truth

Where docs disagree, [Architecture](architecture.md) and [Provider Model](provider-model.md) win. Any API rename must update those two first, then the README and integration docs.
