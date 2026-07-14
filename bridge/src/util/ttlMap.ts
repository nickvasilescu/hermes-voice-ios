export interface TTLMapOptions {
  /** How long an entry lives after being `set` (or last refreshed by `set`). */
  ttlMs: number;
  /** Hard cap on entry count; oldest-inserted entry is evicted once exceeded. */
  maxEntries: number;
  /** Injectable clock for deterministic tests. Defaults to `Date.now`. */
  clock?: () => number;
}

interface Entry<V> {
  value: V;
  expiresAt: number;
}

/**
 * A bounded, TTL-evicting map. Used everywhere this backend holds
 * client-influenced or otherwise unbounded state in memory (client
 * sessions, tasks, idempotency keys, rate-limit buckets) so none of them
 * can grow without limit or outlive their usefulness. [IMPLEMENTED]
 *
 * Eviction is two-pronged: entries older than `ttlMs` since their last
 * `set` are treated as gone on read (lazy expiry, no background timer
 * needed), and if the map ever holds more than `maxEntries` live+expired
 * entries, the oldest-inserted one is dropped immediately on `set`. Reads
 * (`get`/`peek`/`values`) never extend an entry's life — only `set` does —
 * so callers get predictable, fixed-TTL semantics.
 */
export class TTLMap<K, V> {
  private readonly store = new Map<K, Entry<V>>();
  private readonly ttlMs: number;
  private readonly maxEntries: number;
  private readonly clock: () => number;

  constructor(options: TTLMapOptions) {
    this.ttlMs = options.ttlMs;
    this.maxEntries = options.maxEntries;
    this.clock = options.clock ?? (() => Date.now());
  }

  get size(): number {
    return this.store.size;
  }

  set(key: K, value: V): void {
    // Re-inserting moves the key to the end of Map's iteration order, so
    // repeatedly-written keys aren't the ones evicted first.
    this.store.delete(key);
    this.store.set(key, { value, expiresAt: this.clock() + this.ttlMs });
    this.evictIfNeeded();
  }

  get(key: K): V | undefined {
    return this.read(key);
  }

  /** Identical to `get` — named separately so call sites can document intent. */
  peek(key: K): V | undefined {
    return this.read(key);
  }

  delete(key: K): void {
    this.store.delete(key);
  }

  purgeExpired(): void {
    const now = this.clock();
    for (const [key, entry] of this.store) {
      if (entry.expiresAt <= now) this.store.delete(key);
    }
  }

  *values(): IterableIterator<V> {
    const now = this.clock();
    for (const [key, entry] of [...this.store]) {
      if (entry.expiresAt <= now) {
        this.store.delete(key);
        continue;
      }
      yield entry.value;
    }
  }

  private read(key: K): V | undefined {
    const entry = this.store.get(key);
    if (!entry) return undefined;
    if (entry.expiresAt <= this.clock()) {
      this.store.delete(key);
      return undefined;
    }
    return entry.value;
  }

  private evictIfNeeded(): void {
    while (this.store.size > this.maxEntries) {
      const oldestKey = this.store.keys().next().value;
      if (oldestKey === undefined) break;
      this.store.delete(oldestKey);
    }
  }
}
