# Kits and Platforms

`git-pont` should be designed as a family of reusable platform libraries that share one provider-neutral contract. Kits are reserved for app/demo bundles or composed starter integrations.

The first library is the Swift implementation:

```txt
libs/swift
```

`libs/swift` is implemented as a Swift Package for Apple platforms and was the first v1 implementation target. Lezin and GitFolder are the first consumers. A TypeScript library (`libs/typescript`) and Cloudflare Worker kit (`kits/worker`) now sit alongside it — see below.

The repository root also contains a public `Package.swift` that points SwiftPM at the `libs/swift` source and test paths. External Swift projects should depend on the repository URL, not on a `libs/swift` subdirectory URL.

A TypeScript implementation now exists alongside the Swift library, following the
same libs-vs-kits split — a reusable library plus a deployable service:

```txt
libs/typescript   @git-pont/core    TypeScript port of the contract (auth + REST proxy)
kits/worker        @git-pont/worker  Cloudflare Worker consuming @git-pont/core
```

`libs/typescript` is a framework-agnostic library (fetch + WebCrypto only) that
runs in Workers, Node, and browsers, mirroring `libs/swift`; `kits/worker` is a
deployable app kit that adds OAuth callback handling, sessions, and persistence
for web consumers such as gitKanban. See [TypeScript Core Kit](typescript-kit.md)
and [Cloudflare Worker Service](worker-service.md).

Further libraries may be added without changing the shared product model:

```txt
libs/kotlin       Kotlin/Android
```

These names are planning labels, not committed package names.

## Shared Contract

Every reusable library should implement the same behavioral contract:

- supported provider kinds and provider instances
- normalized repository, branch, file, directory, commit, and pull request models
- two-phase URL parsing with slashed-branch ambiguity resolution
- conflict-safe file create/update/delete behavior
- direct commit, branch + pull request, and fork + pull request submission flows
- provider-neutral authentication and credential storage concepts
- normalized errors that preserve provider context without leaking secrets
- internal pagination with a truncation flag
- no content-type assumptions about file data
- no app-specific UI or settings ownership

For v1, the canonical contract is expressed in Swift in [Architecture](architecture.md) and [Provider Model](provider-model.md). Future libraries should translate those models idiomatically while preserving field meanings and behavior.

## Swift Library Boundary

The Swift library owns:

- Swift public API
- async/await implementation
- Apple Keychain credential store module
- native OAuth helper primitives where useful
- Git CLI credential context for macOS apps that shell out to `git`

The Swift library must not bake in Apple-only assumptions into provider semantics. In particular:

- URL parsing rules must not depend on Foundation-specific quirks.
- Provider model fields must map cleanly to JSON-like data shapes.
- Credential and connection persistence must stay behind protocols.
- Network behavior must stay behind an injected HTTP client.
- Core models should avoid UI framework types.

## Future Kit Notes

Android would likely provide:

- Kotlin data classes matching the shared model
- coroutine-based async APIs
- Android Keystore-backed credential storage
- browser/custom-tab OAuth helpers

Web would likely provide:

- TypeScript types matching the shared model
- fetch-based HTTP client injection
- storage adapters selected by the consuming app
- OAuth flows appropriate for browser or backend-mediated auth

None of this is v1 scope. It only constrains v1 documentation and API design so the Swift package is not a dead end.
