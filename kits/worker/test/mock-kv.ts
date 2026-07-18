/** Minimal in-memory KVNamespace stand-in for tests. */
export class MockKV {
  readonly store = new Map<string, string>();

  async get(key: string): Promise<string | null> {
    return this.store.get(key) ?? null;
  }

  async put(key: string, value: string): Promise<void> {
    this.store.set(key, value);
  }

  async delete(key: string): Promise<void> {
    this.store.delete(key);
  }

  async list(options?: { prefix?: string }): Promise<{ keys: { name: string }[] }> {
    const prefix = options?.prefix ?? "";
    const keys = [...this.store.keys()]
      .filter((name) => name.startsWith(prefix))
      .map((name) => ({ name }));
    return { keys };
  }
}
