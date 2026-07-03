# Provider APIs

This document describes the provider-specific API mapping for every operation in the `GitProvider` protocol. The implementation agent should verify endpoint details against current official docs before coding.

## Pagination

All list endpoints below are paginated. Providers must request `per_page=100` (GitLab: `per_page=100`), follow pagination until exhausted, and stop at the safety cap defined in [Architecture → Pagination](architecture.md).

- GitHub, Forgejo, Gitea: follow the `Link: <...>; rel="next"` response header.
- GitLab: follow the `x-next-page` response header (empty when done).

## GitHub

Base:

```txt
Web: https://github.com
API: https://api.github.com
```

Account (connection validation):

```txt
GET /user
```

List repositories:

```txt
GET /user/repos?per_page=100&sort=updated
```

Repository metadata (includes `permissions`, `default_branch`, `parent` for forks):

```txt
GET /repos/{owner}/{repo}
```

List branches:

```txt
GET /repos/{owner}/{repo}/branches?per_page=100
```

Read file:

```txt
GET /repos/{owner}/{repo}/contents/{path}?ref={ref}
```

Size limit: the contents API returns Base64 content up to 1 MB. Between 1 MB and 100 MB it returns `content: ""` with `encoding: "none"`; the provider must then fetch the blob via

```txt
GET /repos/{owner}/{repo}/git/blobs/{file_sha}
```

Above 100 MB, throw `.fileTooLarge(size:limit:)`.

List directory: same contents endpoint with a directory path returns a JSON array of entries.

Commit file (create or update):

```txt
PUT /repos/{owner}/{repo}/contents/{path}
```

Payload includes:

- `message`
- `content` as Base64
- `sha` for updates/conflict protection (from `expectedVersion .blobSHA`)
- `branch`
- optional `committer`/`author` name and email

A `409`/`422` referencing SHA mismatch maps to `.conflict`. The response contains the new blob `sha` for `GitCommitResult.newVersion`.

Delete file:

```txt
DELETE /repos/{owner}/{repo}/contents/{path}
```

Payload includes `message`, `sha`, `branch`.

Create branch:

1. Load base ref: `GET /repos/{owner}/{repo}/git/ref/heads/{branch}` (or use a commit SHA directly)
2. Create ref: `POST /repos/{owner}/{repo}/git/refs` with `ref: "refs/heads/{name}"`, `sha`

Delete branch:

```txt
DELETE /repos/{owner}/{repo}/git/ref/heads/{branch}
```

Create repository:

```txt
POST /user/repos                (personal namespace)
POST /orgs/{org}/repos          (organization namespace)
```

Fork repository:

```txt
POST /repos/{owner}/{repo}/forks
```

Forking is asynchronous: the response returns immediately but the fork may not be ready. Poll `GET /repos/{forkOwner}/{repo}` until it succeeds (bounded, see Architecture). Detect an existing fork by checking the authenticated user's repo of the same name whose `parent` matches.

Create pull request:

```txt
POST /repos/{owner}/{repo}/pulls
```

For same-repo PRs, `head` is the branch name. For fork PRs, `head` is `{forkOwner}:{branch}`. `draft: true` for draft PRs.

## GitLab.com and Self-Hosted GitLab

Base:

```txt
GitLab.com API: https://gitlab.com/api/v4
Self-hosted:    {baseURL}/api/v4
```

Project ID can be the numeric ID or URL-encoded namespace path. Prefer URL-encoded namespace path when parsing from URLs.

Account:

```txt
GET /user
```

List repositories (projects the user is a member of):

```txt
GET /projects?membership=true&per_page=100&order_by=last_activity_at
```

Project metadata (includes `default_branch`, `permissions`, `forked_from_project`):

```txt
GET /projects/:id
```

List branches:

```txt
GET /projects/:id/repository/branches?per_page=100
```

Read file:

```txt
GET /projects/:id/repository/files/:file_path?ref=:ref
```

File response includes:

- `content` Base64 encoded
- `last_commit_id`
- `blob_id`
- `content_sha256`
- `size`

No hard 1 MB limit like GitHub, but responses are memory-bound; enforce the same app-side limit and throw `.fileTooLarge` above 100 MB.

List directory:

```txt
GET /projects/:id/repository/tree?path=:path&ref=:ref&per_page=100
```

Update file:

```txt
PUT /projects/:id/repository/files/:file_path
```

Payload includes:

- `branch`
- `commit_message`
- `content`
- `encoding` optionally `base64`
- `last_commit_id` for conflict protection (from `expectedVersion .commitID`)
- `start_branch` for branch creation from another branch (`GitFileChange.baseBranch`)
- optional `author_name` / `author_email`

A `400` with "You are attempting to update a file that has changed since you started editing it" maps to `.conflict`. The update response does not return the new `last_commit_id`; the provider must re-read the file metadata (`GET .../files/:file_path?ref=:branch` or `HEAD` with `x-gitlab-last-commit-id` header) to populate `GitCommitResult.newVersion`.

Create file:

```txt
POST /projects/:id/repository/files/:file_path
```

Delete file:

```txt
DELETE /projects/:id/repository/files/:file_path
```

Payload includes `branch`, `commit_message`, and `last_commit_id` for conflict protection.

Create branch:

```txt
POST /projects/:id/repository/branches?branch={name}&ref={fromRef}
```

Delete branch:

```txt
DELETE /projects/:id/repository/branches/{branch}
```

Create repository:

```txt
POST /projects            (name, visibility, initialize_with_readme, namespace_id optional)
```

Fork repository:

```txt
POST /projects/:id/fork
```

Fork may be processed asynchronously (`import_status`); poll `GET /projects/:forkID` until `import_status` is `finished` or absent.

Create merge request:

```txt
POST /projects/:id/merge_requests
```

For fork MRs, call this on the fork project with `target_project_id` set to the upstream project ID. Draft MRs are expressed by prefixing the title with `Draft: `.

## Forgejo, Gitea, Codeberg

Base:

```txt
API: {baseURL}/api/v1
Codeberg API: https://codeberg.org/api/v1
```

Codeberg is a preset Forgejo instance; there is no separate Codeberg code path.

Forgejo and Gitea expose OpenAPI at:

```txt
{baseURL}/swagger.v1.json
```

Account:

```txt
GET /user
```

List repositories:

```txt
GET /user/repos?limit=50&page={n}
```

Repository metadata (includes `permissions`, `default_branch`, `parent`):

```txt
GET /repos/{owner}/{repo}
```

List branches:

```txt
GET /repos/{owner}/{repo}/branches
```

File and directory operations use the GitHub-like contents API:

```txt
GET    /repos/{owner}/{repo}/contents/{filepath}?ref={ref}
PUT    /repos/{owner}/{repo}/contents/{filepath}     (update; requires "sha")
POST   /repos/{owner}/{repo}/contents/{filepath}     (create)
DELETE /repos/{owner}/{repo}/contents/{filepath}     (requires "sha")
```

For updates and deletes the file `sha` is required by the API — conflict protection is mandatory here, which matches the GitPont default. A SHA mismatch maps to `.conflict`.

Create branch:

```txt
POST /repos/{owner}/{repo}/branches     (new_branch_name, old_ref_name)
```

Delete branch:

```txt
DELETE /repos/{owner}/{repo}/branches/{branch}
```

Create repository:

```txt
POST /user/repos
POST /orgs/{org}/repos
```

Fork repository:

```txt
POST /repos/{owner}/{repo}/forks
```

Create pull request:

```txt
POST /repos/{owner}/{repo}/pulls
```

Fork PRs use `head: "{forkOwner}:{branch}"` like GitHub.

Because self-hosted instances can run different versions, write integration tests against fixtures and keep provider errors explicit when an endpoint is missing (map 404/405 on a known-path write endpoint to `.unsupportedCapability` with the instance version in the message when available).

## URL Parsing

Support these URL shapes.

GitHub:

```txt
https://github.com/owner/repo/blob/main/path/file.md
https://github.com/owner/repo/blob/{40-char-sha}/path/file.md      (permalink)
https://raw.githubusercontent.com/owner/repo/main/path/file.md
https://raw.githubusercontent.com/owner/repo/refs/heads/main/path/file.md
https://github.com/owner/repo/tree/main/path                       (directory)
https://github.com/owner/repo
```

GitLab:

```txt
https://gitlab.com/group/project/-/blob/main/path/file.md
https://gitlab.com/group/project/-/raw/main/path/file.md
https://gitlab.company.com/group/subgroup/project/-/blob/main/path/file.md
https://gitlab.com/group/project/-/tree/main/path                  (directory)
https://gitlab.com/group/project
```

Forgejo/Gitea/Codeberg:

```txt
https://codeberg.org/owner/repo/src/branch/main/path/file.md
https://codeberg.org/owner/repo/src/commit/{sha}/path/file.md
https://codeberg.org/owner/repo/raw/branch/main/path/file.md
https://git.example.com/owner/repo/src/branch/main/path/file.md
https://git.example.com/owner/repo
```

The parser must preserve:

- provider instance
- namespace
- repo
- ref
- path

Parsing rules:

- Strip query strings and fragments (`?plain=1`, `#L10-L20`) before matching.
- A ref that is a 7–64 character hex string is a commit permalink and is never ambiguous.
- Branch names may contain slashes; when the segment after the ref marker plus remaining path has more than one possible split, return `.ambiguous` with all candidate `(ref, path)` splits, longest-ref first. See [Architecture → URL Parsing Is Two-Phase](architecture.md).
- Forgejo/Gitea `src/branch/` URLs mark the ref boundary explicitly but the ref itself may still contain slashes; the same candidate logic applies. `src/commit/{sha}` is always resolved.
- Trailing `.git` on repository URLs must be stripped.

Do not guess custom-host provider type unless the instance is configured.
