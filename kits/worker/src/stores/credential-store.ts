/**
 * KV-backed `CredentialStore`, scoped to a single user. Credentials are
 * encrypted at rest with AES-GCM (see crypto.ts) — tokens are never stored in
 * plaintext. Keys: `cred:<userId>:<connectionId>`.
 */

import type { CredentialStore, GitCredential } from "@git-pont/core";
import { decryptJSON, encryptJSON } from "../crypto.js";

interface StoredCredential extends Omit<GitCredential, "expiresAt"> {
  expiresAt?: string;
}

function serialize(credential: GitCredential): StoredCredential {
  return {
    ...credential,
    expiresAt: credential.expiresAt ? credential.expiresAt.toISOString() : undefined,
  };
}

function deserialize(stored: StoredCredential): GitCredential {
  return {
    ...stored,
    expiresAt: stored.expiresAt ? new Date(stored.expiresAt) : undefined,
  };
}

export class KVCredentialStore implements CredentialStore {
  private readonly kv: KVNamespace;
  private readonly userId: string;
  private readonly encKey: string;

  constructor(kv: KVNamespace, userId: string, encKey: string) {
    this.kv = kv;
    this.userId = userId;
    this.encKey = encKey;
  }

  private key(connectionID: string): string {
    return `cred:${this.userId}:${connectionID}`;
  }

  async save(credential: GitCredential, connectionID: string): Promise<void> {
    const encrypted = await encryptJSON(this.encKey, serialize(credential));
    await this.kv.put(this.key(connectionID), encrypted);
  }

  async loadCredential(connectionID: string): Promise<GitCredential | undefined> {
    const raw = await this.kv.get(this.key(connectionID));
    if (!raw) return undefined;
    const stored = await decryptJSON<StoredCredential>(this.encKey, raw);
    return deserialize(stored);
  }

  async deleteCredential(connectionID: string): Promise<void> {
    await this.kv.delete(this.key(connectionID));
  }
}
