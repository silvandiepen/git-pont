/**
 * KV-backed `ConnectionStore`, scoped to a single user so the facade never sees
 * another user's connections. Keys: `conn:<userId>:<connectionId>`.
 * Connection metadata contains no secrets, so it is stored as plain JSON.
 */

import type { ConnectionStore, GitConnection } from "@git-pont/core";

interface StoredConnection extends Omit<GitConnection, "createdAt" | "updatedAt"> {
  createdAt: string;
  updatedAt: string;
}

function serialize(connection: GitConnection): StoredConnection {
  return {
    ...connection,
    createdAt: connection.createdAt.toISOString(),
    updatedAt: connection.updatedAt.toISOString(),
  };
}

function deserialize(stored: StoredConnection): GitConnection {
  return {
    ...stored,
    createdAt: new Date(stored.createdAt),
    updatedAt: new Date(stored.updatedAt),
  };
}

export class KVConnectionStore implements ConnectionStore {
  private readonly kv: KVNamespace;
  private readonly userId: string;

  constructor(kv: KVNamespace, userId: string) {
    this.kv = kv;
    this.userId = userId;
  }

  private key(id: string): string {
    return `conn:${this.userId}:${id}`;
  }

  private get prefix(): string {
    return `conn:${this.userId}:`;
  }

  async save(connection: GitConnection): Promise<void> {
    await this.kv.put(this.key(connection.id), JSON.stringify(serialize(connection)));
  }

  async connections(): Promise<GitConnection[]> {
    const result = await this.kv.list({ prefix: this.prefix });
    const connections: GitConnection[] = [];
    for (const entry of result.keys) {
      const raw = await this.kv.get(entry.name);
      if (raw) connections.push(deserialize(JSON.parse(raw) as StoredConnection));
    }
    return connections;
  }

  async connection(id: string): Promise<GitConnection | undefined> {
    const raw = await this.kv.get(this.key(id));
    return raw ? deserialize(JSON.parse(raw) as StoredConnection) : undefined;
  }

  async delete(id: string): Promise<void> {
    await this.kv.delete(this.key(id));
  }
}
