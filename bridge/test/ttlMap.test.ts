import { test } from "node:test";
import assert from "node:assert/strict";
import { TTLMap } from "../src/util/ttlMap.js";

test("TTLMap.get returns undefined for a missing key", () => {
  const map = new TTLMap<string, number>({ ttlMs: 1000, maxEntries: 10 });
  assert.equal(map.get("a"), undefined);
});

test("TTLMap.set/get round-trips a value", () => {
  const map = new TTLMap<string, number>({ ttlMs: 1000, maxEntries: 10 });
  map.set("a", 1);
  assert.equal(map.get("a"), 1);
  assert.equal(map.size, 1);
});

test("TTLMap.get returns undefined and deletes once a key expires", () => {
  let now = 0;
  const map = new TTLMap<string, number>({ ttlMs: 100, maxEntries: 10, clock: () => now });
  map.set("a", 1);
  now = 50;
  assert.equal(map.get("a"), 1);
  now = 150;
  assert.equal(map.get("a"), undefined);
  assert.equal(map.size, 0);
});

test("TTLMap.set refreshes TTL (sliding expiry)", () => {
  let now = 0;
  const map = new TTLMap<string, number>({ ttlMs: 100, maxEntries: 10, clock: () => now });
  map.set("a", 1);
  now = 80;
  map.set("a", 2); // refresh
  now = 150;
  assert.equal(map.get("a"), 2, "should still be alive: 80 + 100 > 150");
});

test("TTLMap evicts the oldest entry once maxEntries is exceeded", () => {
  const map = new TTLMap<string, number>({ ttlMs: 100_000, maxEntries: 2 });
  map.set("a", 1);
  map.set("b", 2);
  map.set("c", 3);
  assert.equal(map.size, 2);
  assert.equal(map.get("a"), undefined, "oldest entry should have been evicted");
  assert.equal(map.get("b"), 2);
  assert.equal(map.get("c"), 3);
});

test("TTLMap.delete removes a key", () => {
  const map = new TTLMap<string, number>({ ttlMs: 1000, maxEntries: 10 });
  map.set("a", 1);
  map.delete("a");
  assert.equal(map.get("a"), undefined);
  assert.equal(map.size, 0);
});

test("TTLMap.purgeExpired removes all expired entries without touching live ones", () => {
  let now = 0;
  const map = new TTLMap<string, number>({ ttlMs: 100, maxEntries: 10, clock: () => now });
  map.set("a", 1);
  now = 200;
  map.set("b", 2);
  map.purgeExpired();
  assert.equal(map.size, 1);
  assert.equal(map.get("b"), 2);
});

test("TTLMap.values yields only live values", () => {
  let now = 0;
  const map = new TTLMap<string, number>({ ttlMs: 100, maxEntries: 10, clock: () => now });
  map.set("a", 1);
  now = 200;
  map.set("b", 2);
  assert.deepEqual([...map.values()], [2]);
});

test("TTLMap.peek reads a value without refreshing its TTL", () => {
  let now = 0;
  const map = new TTLMap<string, number>({ ttlMs: 100, maxEntries: 10, clock: () => now });
  map.set("a", 1);
  now = 50;
  assert.equal(map.peek("a"), 1);
  now = 150;
  assert.equal(map.peek("a"), undefined);
});
