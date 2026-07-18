/**
 * In-memory reference implementations of the store contracts. Useful for tests
 * and simple consumers. The worker kit provides Cloudflare KV-backed stores.
 */

import type { GitConnection, GitCredential } from "./models.js";
import type { ConnectionStore, CredentialStore } from "./protocols.js";

export class InMemoryConnectionStore implements ConnectionStore {
  private readonly items = new Map<string, GitConnection>();

  async save(connection: GitConnection): Promise<void> {
    this.items.set(connection.id, connection);
  }

  async connections(): Promise<GitConnection[]> {
    return [...this.items.values()];
  }

  async connection(id: string): Promise<GitConnection | undefined> {
    return this.items.get(id);
  }

  async delete(id: string): Promise<void> {
    this.items.delete(id);
  }
}

export class InMemoryCredentialStore implements CredentialStore {
  private readonly items = new Map<string, GitCredential>();

  async save(credential: GitCredential, connectionID: string): Promise<void> {
    this.items.set(connectionID, credential);
  }

  async loadCredential(connectionID: string): Promise<GitCredential | undefined> {
    return this.items.get(connectionID);
  }

  async deleteCredential(connectionID: string): Promise<void> {
    this.items.delete(connectionID);
  }
}
