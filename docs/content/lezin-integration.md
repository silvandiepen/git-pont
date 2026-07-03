# Lezin Integration

Lezin should use `git-pont` only for remote document operations. It should not depend on GitFolder and should not shell out to Git.

## User Flows

### Open From Git URL

Menu:

```txt
File > Open from Git URL...
```

Flow:

1. User pastes a GitHub/GitLab/Forgejo/Gitea/Codeberg file URL.
2. Lezin calls `gitPont.openFile(from:)`. URL ambiguity (slashed branch names) is resolved inside git-pont; Lezin never sees it.
3. If public read works, open immediately.
4. If `.authenticationRequired` or `.missingConnection`, show the connection flow, then retry.
5. Store the loaded `GitRemoteFile.reference` and `version` with the document.
6. Also fetch `gitPont.repository(file.reference.repository)` and keep `permissions` — the save UI depends on it.

### Browse a Connected Repository (optional but recommended)

Paste-a-URL is a power-user flow. A picker is friendlier:

1. User picks a connection.
2. `gitPont.repositories(connectionID:)` → repo list (`truncated` flag shown as "showing first 3000").
3. `gitPont.branches(of:)` → branch choice, default branch preselected.
4. `gitPont.listDirectory(_:)` → file tree; opening a file calls `readFile`.

### Save Remote Document

For a remote document, normal save becomes commit behavior. What the dialog offers depends on `GitRepository.permissions`:

- `canPush == true`: offer **Commit to {branch}** and **Commit to new branch + open {PR/MR}**.
- `canPush == false`: offer only **Propose change (fork + {PR/MR})** — this is the common case for files the user does not own. Never show a direct-commit option that is guaranteed to fail with 403.

Use `provider.changeRequestTerm` for the PR/MR label.

Flow:

1. User saves.
2. If document source is remote, show commit dialog.
3. Lezin builds a `GitChangeSubmission` and calls `gitPont.submitChange(_:)`:
   - direct commit → `.directCommit`
   - new branch + PR → `.branchAndPullRequest(...)`
   - no push access → `.forkAndPullRequest(...)`
   - or simply `.automatic(...)` and let git-pont decide
4. On success, update the stored remote version from `GitChangeResult.commit.newVersion`, update the stored reference to `usedRepository`/`usedBranch` (it may now point at a fork branch), clear dirty state, and offer to open `pullRequest.webURL` when one was created.
5. On `.conflict`, show conflict UI and do not overwrite.
6. On `.partialSubmission`, tell the user what succeeded (for example "committed, but opening the PR failed") and offer retry of only the missing step.

## Document Source

Lezin should introduce a source enum:

```swift
enum DocumentSource {
    case local(URL)
    case remote(GitFileReference, version: GitRemoteVersion?, permissions: GitRepositoryPermissions?)
    case unsaved
}
```

## Commit Dialog

Fields:

- commit message
- target branch (hidden when forking; git-pont picks the fork branch name from the submission)
- optional create new branch (name defaulted to `lezin/{slugified-filename}`)
- optional open PR/MR after commit (with title/body fields; term from `changeRequestTerm`)

Default message:

```txt
Update {filename}
```

## Staleness Check

Before the user starts a long edit, or on window focus, Lezin may call `gitPont.checkForRemoteChange(_:)`. If it returns true, show a non-blocking "remote has changed" banner so the user can reload before investing more work. This is advisory; the commit-time version check remains the real protection.

## Conflict Handling

If `git-pont` returns `.conflict`:

- Do not silently overwrite.
- Offer reload remote, copy local changes, or save to new branch (a `.branchAndPullRequest` submission sidesteps the conflict).
- Keep local editor content intact.

## Settings

Settings should show provider connections:

```txt
Settings > Integrations
├─ GitHub
├─ GitLab.com
├─ Self-hosted GitLab
├─ Codeberg
├─ Forgejo
└─ Gitea
```

Multiple connections per provider are allowed (personal + work). When a URL matches an instance with several connections, git-pont throws `.ambiguousConnection`; Lezin shows a picker and stores the chosen `connectionID` with the document.

Lezin should let users enable/disable integrations, but disabled integrations should not delete stored credentials unless the user explicitly disconnects.
