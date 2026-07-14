import { test } from "node:test";
import assert from "node:assert/strict";
import { ClientSessionStore } from "../src/auth/clientSession.js";

test("ClientSessionStore.create mints a unique token and a server-selected hermesSessionId", () => {
  const store = new ClientSessionStore({ ttlMs: 60_000, maxEntries: 10 });
  const a = store.create();
  const b = store.create();

  assert.notEqual(a.token, b.token);
  assert.notEqual(a.hermesSessionId, b.hermesSessionId);
  assert.match(a.token, /^st_/);
  assert.match(a.hermesSessionId, /^hs_/);
});

test("ClientSessionStore.validate resolves a freshly minted token to its hermesSessionId", () => {
  const store = new ClientSessionStore({ ttlMs: 60_000, maxEntries: 10 });
  const { token, hermesSessionId } = store.create();

  const resolved = store.validate(token);
  assert.equal(resolved?.hermesSessionId, hermesSessionId);
});

test("ClientSessionStore.validate rejects an unknown token", () => {
  const store = new ClientSessionStore({ ttlMs: 60_000, maxEntries: 10 });
  assert.equal(store.validate("st_not_a_real_token"), undefined);
});

test("ClientSessionStore.validate rejects an expired token", () => {
  let now = 0;
  const store = new ClientSessionStore({ ttlMs: 1000, maxEntries: 10, clock: () => now });
  const { token } = store.create();
  now = 2000;
  assert.equal(store.validate(token), undefined);
});

test("ClientSessionStore never stores the plaintext token", () => {
  const store = new ClientSessionStore({ ttlMs: 60_000, maxEntries: 10 });
  const { token } = store.create();
  const dump = JSON.stringify(store.debugDumpForTests());
  assert.ok(!dump.includes(token), "plaintext token must never appear in the store's internal state");
});

test("ClientSessionStore is bounded: oldest session is evicted past maxEntries", () => {
  const store = new ClientSessionStore({ ttlMs: 60_000, maxEntries: 2 });
  const a = store.create();
  store.create();
  store.create();
  assert.equal(store.validate(a.token), undefined, "oldest session should have been evicted");
});
