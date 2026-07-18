/**
 * Session records mapping an opaque session id to a user and their
 * connection ids. Keys: `session:<sessionId>`. The session id is a random
 * 256-bit token; it is unguessable, so KV lookup is the source of truth.
 */

import { randomId } from "../crypto.js";

export interface SessionRecord {
  userId: string;
  connectionIds: string[];
  createdAt: string;
  expiresAt: string;
}

export class SessionStore {
  private readonly kv: KVNamespace;
  private readonly ttlSeconds: number;

  constructor(kv: KVNamespace, ttlSeconds: number) {
    this.kv = kv;
    this.ttlSeconds = ttlSeconds;
  }

  private key(sessionId: string): string {
    return `session:${sessionId}`;
  }

  async create(userId: string, connectionIds: string[]): Promise<string> {
    const sessionId = randomId(32);
    const now = Date.now();
    const record: SessionRecord = {
      userId,
      connectionIds,
      createdAt: new Date(now).toISOString(),
      expiresAt: new Date(now + this.ttlSeconds * 1000).toISOString(),
    };
    await this.kv.put(this.key(sessionId), JSON.stringify(record), {
      expirationTtl: this.ttlSeconds,
    });
    return sessionId;
  }

  async get(sessionId: string): Promise<SessionRecord | undefined> {
    const raw = await this.kv.get(this.key(sessionId));
    if (!raw) return undefined;
    const record = JSON.parse(raw) as SessionRecord;
    if (Date.parse(record.expiresAt) <= Date.now()) {
      await this.destroy(sessionId);
      return undefined;
    }
    return record;
  }

  async destroy(sessionId: string): Promise<void> {
    await this.kv.delete(this.key(sessionId));
  }
}
