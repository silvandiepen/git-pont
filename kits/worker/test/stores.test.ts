import { describe, expect, it } from "vitest";
import { GitProviderInstances, type GitConnection, type GitCredential } from "@git-pont/core";
import { decryptJSON, encryptJSON, randomId } from "../src/crypto.js";
import { KVConnectionStore } from "../src/stores/connection-store.js";
import { KVCredentialStore } from "../src/stores/credential-store.js";
import { SessionStore } from "../src/stores/session-store.js";
import { ProfileStore } from "../src/stores/profile-store.js";
import { MockKV } from "./mock-kv.js";

// 32-byte base64 key for AES-GCM.
const ENC_KEY = Buffer.from(new Uint8Array(32).fill(7)).toString("base64");
const github = GitProviderInstances.github;

describe("crypto", () => {
  it("round-trips an encrypted JSON value", async () => {
    const value = { token: "super-secret", n: 1 };
    const encrypted = await encryptJSON(ENC_KEY, value);
    expect(encrypted).not.toContain("super-secret");
    expect(await decryptJSON(ENC_KEY, encrypted)).toEqual(value);
  });

  it("produces distinct ciphertexts for the same input (random IV)", async () => {
    const a = await encryptJSON(ENC_KEY, { x: 1 });
    const b = await encryptJSON(ENC_KEY, { x: 1 });
    expect(a).not.toEqual(b);
  });

  it("generates unique ids", () => {
    expect(randomId()).not.toEqual(randomId());
  });
});

describe("KVCredentialStore", () => {
  it("stores credentials encrypted and revives the Date on load", async () => {
    const kv = new MockKV();
    const store = new KVCredentialStore(kv as unknown as KVNamespace, "github:1", ENC_KEY);
    const credential: GitCredential = {
      accessToken: "gho_plaintexttoken",
      refreshToken: "r",
      expiresAt: new Date("2030-01-01T00:00:00.000Z"),
      scopes: ["repo"],
    };
    await store.save(credential, "conn1");

    // The token must not appear in plaintext anywhere in KV.
    for (const raw of kv.store.values()) {
      expect(raw).not.toContain("gho_plaintexttoken");
    }

    const loaded = await store.loadCredential("conn1");
    expect(loaded?.accessToken).toBe("gho_plaintexttoken");
    expect(loaded?.expiresAt).toBeInstanceOf(Date);
    expect(loaded?.expiresAt?.toISOString()).toBe("2030-01-01T00:00:00.000Z");
  });
});

describe("KVConnectionStore", () => {
  it("saves, lists, gets, and deletes scoped to the user", async () => {
    const kv = new MockKV();
    const store = new KVConnectionStore(kv as unknown as KVNamespace, "github:1");
    const other = new KVConnectionStore(kv as unknown as KVNamespace, "github:2");
    const connection: GitConnection = {
      id: "c1",
      instance: github,
      accountID: "1",
      accountLogin: "octocat",
      authMethod: "oauthPKCE",
      createdAt: new Date("2026-01-01T00:00:00.000Z"),
      updatedAt: new Date("2026-01-02T00:00:00.000Z"),
    };
    await store.save(connection);

    // Other users see nothing.
    expect(await other.connections()).toHaveLength(0);

    const list = await store.connections();
    expect(list).toHaveLength(1);
    expect(list[0]?.createdAt).toBeInstanceOf(Date);
    expect(list[0]?.accountLogin).toBe("octocat");

    await store.delete("c1");
    expect(await store.connection("c1")).toBeUndefined();
  });
});

describe("SessionStore", () => {
  it("creates, reads, and destroys sessions", async () => {
    const kv = new MockKV();
    const store = new SessionStore(kv as unknown as KVNamespace, 3600);
    const id = await store.create("github:1", ["c1"]);
    const record = await store.get(id);
    expect(record?.userId).toBe("github:1");
    expect(record?.connectionIds).toEqual(["c1"]);
    await store.destroy(id);
    expect(await store.get(id)).toBeUndefined();
  });
});

describe("ProfileStore", () => {
  it("merges patches and de-duplicates recent repos", async () => {
    const kv = new MockKV();
    const store = new ProfileStore(kv as unknown as KVNamespace);

    await store.patch("github:1", { colorMode: "dark", preferences: { board: "kanban" } });
    await store.touchRecentRepo("github:1", { instanceId: github.id, namespace: "o", name: "r" });
    await store.touchRecentRepo("github:1", { instanceId: github.id, namespace: "o", name: "r" });
    await store.touchRecentRepo("github:1", { instanceId: github.id, namespace: "o", name: "r2" });

    const profile = await store.get("github:1");
    expect(profile.colorMode).toBe("dark");
    expect(profile.preferences.board).toBe("kanban");
    expect(profile.recentRepos).toHaveLength(2);
    // Most recently touched first.
    expect(profile.recentRepos[0]?.name).toBe("r2");
  });
});
