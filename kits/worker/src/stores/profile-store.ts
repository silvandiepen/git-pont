/**
 * Per-user profile document for lightweight preferences (color mode, recently
 * used repositories, ...). Non-sensitive, stored as plain JSON.
 * Keys: `profile:<userId>`.
 */

export interface RecentRepo {
  instanceId: string;
  namespace: string;
  name: string;
  lastOpenedAt: string;
}

export interface UserProfile {
  colorMode?: "light" | "dark" | "system";
  recentRepos: RecentRepo[];
  /** Free-form app preferences bag for the consuming app (e.g. gitKanban). */
  preferences: Record<string, unknown>;
}

const MAX_RECENT = 20;

function emptyProfile(): UserProfile {
  return { recentRepos: [], preferences: {} };
}

export class ProfileStore {
  private readonly kv: KVNamespace;

  constructor(kv: KVNamespace) {
    this.kv = kv;
  }

  private key(userId: string): string {
    return `profile:${userId}`;
  }

  async get(userId: string): Promise<UserProfile> {
    const raw = await this.kv.get(this.key(userId));
    if (!raw) return emptyProfile();
    return { ...emptyProfile(), ...(JSON.parse(raw) as Partial<UserProfile>) };
  }

  async save(userId: string, profile: UserProfile): Promise<void> {
    await this.kv.put(this.key(userId), JSON.stringify(profile));
  }

  /** Shallow-merge a partial update into the stored profile. */
  async patch(userId: string, patch: Partial<UserProfile>): Promise<UserProfile> {
    const current = await this.get(userId);
    const next: UserProfile = {
      ...current,
      ...patch,
      preferences: { ...current.preferences, ...(patch.preferences ?? {}) },
    };
    await this.save(userId, next);
    return next;
  }

  /** Record a repository as recently used, most-recent first, de-duplicated. */
  async touchRecentRepo(userId: string, repo: Omit<RecentRepo, "lastOpenedAt">): Promise<void> {
    const profile = await this.get(userId);
    const filtered = profile.recentRepos.filter(
      (r) => !(r.instanceId === repo.instanceId && r.namespace === repo.namespace && r.name === repo.name),
    );
    filtered.unshift({ ...repo, lastOpenedAt: new Date().toISOString() });
    profile.recentRepos = filtered.slice(0, MAX_RECENT);
    await this.save(userId, profile);
  }
}
