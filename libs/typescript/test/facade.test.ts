import { describe, expect, it } from "vitest";
import {
  GitHubProvider,
  GitPont,
  GitPontError,
  GitProviderInstances,
  InMemoryConnectionStore,
  InMemoryCredentialStore,
  type GitConnection,
} from "../src/index.js";
import { MockHttpClient, countCalls, jsonResponse } from "./helpers.js";

const github = GitProviderInstances.github;

function connection(id: string): GitConnection {
  return {
    id,
    instance: github,
    accountID: id,
    accountLogin: `user-${id}`,
    authMethod: "oauthPKCE",
    createdAt: new Date(),
    updatedAt: new Date(),
  };
}

const noopRetry = { maxRetries: 0, sleep: async () => {} };

describe("GitPont connection resolution", () => {
  it("throws missingConnection when none exist", async () => {
    const gitPont = new GitPont({
      providers: [new GitHubProvider(new MockHttpClient(() => jsonResponse(200, {})))],
      connectionStore: new InMemoryConnectionStore(),
      credentialStore: new InMemoryCredentialStore(),
      retryPolicy: noopRetry,
    });
    await expect(gitPont.connection(github)).rejects.toMatchObject({ code: "missingConnection" });
  });

  it("returns the sole connection automatically", async () => {
    const connections = new InMemoryConnectionStore();
    await connections.save(connection("a"));
    const gitPont = new GitPont({
      providers: [new GitHubProvider(new MockHttpClient(() => jsonResponse(200, {})))],
      connectionStore: connections,
      credentialStore: new InMemoryCredentialStore(),
      retryPolicy: noopRetry,
    });
    const resolved = await gitPont.connection(github);
    expect(resolved.id).toBe("a");
  });

  it("throws ambiguousConnection with multiple matches", async () => {
    const connections = new InMemoryConnectionStore();
    await connections.save(connection("a"));
    await connections.save(connection("b"));
    const gitPont = new GitPont({
      providers: [new GitHubProvider(new MockHttpClient(() => jsonResponse(200, {})))],
      connectionStore: connections,
      credentialStore: new InMemoryCredentialStore(),
      retryPolicy: noopRetry,
    });
    await expect(gitPont.connection(github)).rejects.toMatchObject({ code: "ambiguousConnection" });
  });
});

describe("GitPont token refresh", () => {
  it("serializes concurrent refreshes into a single provider call", async () => {
    const connections = new InMemoryConnectionStore();
    const credentials = new InMemoryCredentialStore();
    const conn = connection("a");
    await connections.save(conn);
    // Credential is already expiring and has a refresh token.
    await credentials.save(
      { accessToken: "old", refreshToken: "r", expiresAt: new Date(Date.now() + 1000), scopes: [] },
      conn.id,
    );

    const client = new MockHttpClient((req) => {
      if (req.url === "https://github.com/login/oauth/access_token") {
        return jsonResponse(200, { access_token: "new", refresh_token: "r2", expires_in: 3600 });
      }
      // user/repos
      return jsonResponse(200, []);
    });
    const provider = new GitHubProvider(client, { clientID: "cid", clientSecret: "sec", scopes: [] });
    const gitPont = new GitPont({
      providers: [provider],
      connectionStore: connections,
      credentialStore: credentials,
      retryPolicy: noopRetry,
    });

    await Promise.all([gitPont.repositories(conn.id), gitPont.repositories(conn.id)]);

    const refreshCalls = countCalls(
      client,
      (r) => r.url === "https://github.com/login/oauth/access_token",
    );
    expect(refreshCalls).toBe(1);
    // The refreshed credential is persisted.
    const stored = await credentials.loadCredential(conn.id);
    expect(stored?.accessToken).toBe("new");
  });
});

describe("GitPont add/remove connection", () => {
  it("validates the token via account and stores metadata + credential", async () => {
    const connections = new InMemoryConnectionStore();
    const credentials = new InMemoryCredentialStore();
    const client = new MockHttpClient(() => jsonResponse(200, { id: 7, login: "octocat" }));
    const gitPont = new GitPont({
      providers: [new GitHubProvider(client)],
      connectionStore: connections,
      credentialStore: credentials,
      retryPolicy: noopRetry,
      generateID: () => "fixed-id",
    });
    const conn = await gitPont.addConnection(github, { accessToken: "t", scopes: [] }, "oauthPKCE");
    expect(conn.id).toBe("fixed-id");
    expect(conn.accountLogin).toBe("octocat");
    expect(await credentials.loadCredential("fixed-id")).toBeDefined();

    await gitPont.removeConnection("fixed-id");
    expect(await connections.connection("fixed-id")).toBeUndefined();
    expect(await credentials.loadCredential("fixed-id")).toBeUndefined();
  });
});

describe("GitPont URL resolution", () => {
  it("disambiguates a slash-branch URL against the branch list", async () => {
    const client = new MockHttpClient((req) => {
      if (req.url.includes("/branches")) {
        return jsonResponse(200, [{ name: "feature/foo", commit: { sha: "s" } }]);
      }
      throw new GitPontError("notFound", "unexpected");
    });
    const gitPont = new GitPont({
      providers: [new GitHubProvider(client)],
      connectionStore: new InMemoryConnectionStore(),
      credentialStore: new InMemoryCredentialStore(),
      retryPolicy: noopRetry,
    });
    const reference = await gitPont.resolve(
      gitPont.parse("https://github.com/o/r/blob/feature/foo/doc.md"),
    );
    expect(reference.ref).toBe("feature/foo");
    expect(reference.path).toBe("doc.md");
  });
});
