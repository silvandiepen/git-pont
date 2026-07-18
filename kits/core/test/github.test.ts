import { describe, expect, it } from "vitest";
import {
  GitHubProvider,
  GitPontError,
  GitProviderInstances,
  bytesToUtf8,
  type GitProviderRequestContext,
} from "../src/index.js";
import { MockHttpClient, jsonResponse } from "./helpers.js";

const github = GitProviderInstances.github;
const credential = { accessToken: "tok", scopes: ["repo"] };
const authedContext: GitProviderRequestContext = {
  connection: {
    id: "c1",
    instance: github,
    accountID: "1",
    accountLogin: "octocat",
    authMethod: "personalAccessToken",
    createdAt: new Date(),
    updatedAt: new Date(),
  },
  credential,
};

describe("GitHubProvider", () => {
  it("loads the current account", async () => {
    const client = new MockHttpClient((req) => {
      expect(req.url).toBe("https://api.github.com/user");
      expect(req.headers?.["Authorization"]).toBe("Bearer tok");
      return jsonResponse(200, { id: 42, login: "octocat", name: "The Octocat" });
    });
    const provider = new GitHubProvider(client);
    const account = await provider.account(github, credential);
    expect(account.id).toBe("42");
    expect(account.login).toBe("octocat");
    expect(account.displayName).toBe("The Octocat");
  });

  it("lists repositories across paginated pages", async () => {
    let page = 0;
    const client = new MockHttpClient(() => {
      page += 1;
      if (page === 1) {
        return jsonResponse(
          200,
          [{ name: "a", full_name: "octocat/a", private: false, fork: false }],
          { Link: '<https://api.github.com/user/repos?page=2>; rel="next"' },
        );
      }
      return jsonResponse(200, [
        { name: "b", full_name: "octocat/b", private: true, fork: false },
      ]);
    });
    const provider = new GitHubProvider(client);
    const repos = await provider.repositories(authedContext);
    expect(repos.items.map((r) => r.reference.name)).toEqual(["a", "b"]);
    expect(repos.items[1]?.isPrivate).toBe(true);
  });

  it("reads and base64-decodes a file", async () => {
    const client = new MockHttpClient(() =>
      jsonResponse(200, {
        type: "file",
        encoding: "base64",
        size: 5,
        name: "README.md",
        path: "README.md",
        content: btoa("hello"),
        sha: "abc123",
      }),
    );
    const provider = new GitHubProvider(client);
    const file = await provider.readFile(
      { repository: { instance: github, namespace: "o", name: "r" }, path: "README.md", ref: "main" },
      authedContext,
    );
    expect(bytesToUtf8(file.content)).toBe("hello");
    expect(file.version).toEqual({ kind: "blobSHA", sha: "abc123" });
  });

  it("maps a 409 write to a conflict error", async () => {
    const client = new MockHttpClient(() => jsonResponse(409, { message: "conflict" }));
    const provider = new GitHubProvider(client);
    await expect(
      provider.commitFile(
        {
          reference: { repository: { instance: github, namespace: "o", name: "r" }, path: "f.md", ref: "main" },
          content: new Uint8Array([1]),
          message: "m",
          targetBranch: "main",
        },
        authedContext,
      ),
    ).rejects.toMatchObject({ code: "conflict" });
  });

  it("builds a browser OAuth authorization URL", async () => {
    const provider = new GitHubProvider(new MockHttpClient(() => jsonResponse(200, {})), {
      clientID: "cid",
      clientSecret: "secret",
      redirectURI: "https://worker.example/auth/github/callback",
      scopes: ["repo"],
    });
    const start = await provider.startOAuth({ instance: github, method: "oauthPKCE", appConfig: { clientID: "cid", scopes: ["repo"] } });
    expect(start.kind).toBe("browser");
    if (start.kind !== "browser") return;
    expect(start.authorizationURL).toContain("client_id=cid");
    expect(start.authorizationURL).toContain("response_type=code");
    expect(start.state.length).toBeGreaterThan(0);
  });

  it("completes the web OAuth flow by exchanging the code", async () => {
    const client = new MockHttpClient((req) => {
      expect(req.url).toBe("https://github.com/login/oauth/access_token");
      const bodyText = typeof req.body === "string" ? req.body : bytesToUtf8(req.body as Uint8Array);
      expect(bodyText).toContain("code=thecode");
      return jsonResponse(200, { access_token: "at", token_type: "bearer", scope: "repo,read:user" });
    });
    const provider = new GitHubProvider(client, {
      clientID: "cid",
      clientSecret: "secret",
      redirectURI: "https://worker.example/auth/github/callback",
      scopes: ["repo"],
    });
    const cred = await provider.completeOAuth({
      instance: github,
      method: "oauthPKCE",
      appConfig: { clientID: "cid", scopes: ["repo"] },
      callbackURL: "https://worker.example/auth/github/callback?code=thecode&state=s",
    });
    expect(cred.accessToken).toBe("at");
    expect(cred.scopes).toEqual(["repo", "read:user"]);
  });

  it("surfaces OAuth errors as authenticationFailed", async () => {
    const client = new MockHttpClient(() =>
      jsonResponse(200, { error: "bad_verification_code", error_description: "expired" }),
    );
    const provider = new GitHubProvider(client, { clientID: "cid", scopes: [] });
    await expect(
      provider.completeOAuth({
        instance: github,
        method: "oauthPKCE",
        appConfig: { clientID: "cid", scopes: [] },
        callbackURL: "https://x/cb?code=c",
      }),
    ).rejects.toBeInstanceOf(GitPontError);
  });
});
