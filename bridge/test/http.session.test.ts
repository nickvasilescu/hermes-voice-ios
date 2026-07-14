import { test } from "node:test";
import assert from "node:assert/strict";
import { startTestServer, bootstrapSession, readJson } from "./helpers.js";

test("POST /v1/session mints a token, a server-selected hermesSessionId, and an expiry, with no bootstrap secret configured (dev mode)", async () => {
  const server = await startTestServer({ nodeEnv: "development" });
  try {
    const minted = await bootstrapSession(server.baseUrl);
    assert.match(minted.sessionToken, /^st_/);
    assert.match(minted.hermesSessionId, /^hs_/);
    assert.ok(new Date(minted.expiresAt).getTime() > Date.now());
  } finally {
    await server.close();
  }
});

test("POST /v1/session never lets the client choose hermesSessionId", async () => {
  const server = await startTestServer({ nodeEnv: "development" });
  try {
    const res = await fetch(`${server.baseUrl}/v1/session`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ hermesSessionId: "hs_attacker_chosen" }),
    });
    const body = await readJson<{ hermesSessionId: string }>(res);
    assert.notEqual(body.hermesSessionId, "hs_attacker_chosen");
    assert.match(body.hermesSessionId, /^hs_/);
  } finally {
    await server.close();
  }
});

test("each mint produces a distinct token and hermesSessionId", async () => {
  const server = await startTestServer({ nodeEnv: "development" });
  try {
    const a = await bootstrapSession(server.baseUrl);
    const b = await bootstrapSession(server.baseUrl);
    assert.notEqual(a.sessionToken, b.sessionToken);
    assert.notEqual(a.hermesSessionId, b.hermesSessionId);
  } finally {
    await server.close();
  }
});

test("with BRIDGE_BOOTSTRAP_SECRET configured, minting without it is rejected", async () => {
  const server = await startTestServer({ bootstrapSecret: "boot-secret" });
  try {
    const res = await fetch(`${server.baseUrl}/v1/session`, { method: "POST" });
    assert.equal(res.status, 401);
  } finally {
    await server.close();
  }
});

test("with BRIDGE_BOOTSTRAP_SECRET configured, the wrong credential is rejected", async () => {
  const server = await startTestServer({ bootstrapSecret: "boot-secret" });
  try {
    const res = await fetch(`${server.baseUrl}/v1/session`, {
      method: "POST",
      headers: { authorization: "Bearer wrong-secret" },
    });
    assert.equal(res.status, 401);
  } finally {
    await server.close();
  }
});

test("with BRIDGE_BOOTSTRAP_SECRET configured, the right credential mints a session", async () => {
  const server = await startTestServer({ bootstrapSecret: "boot-secret" });
  try {
    const minted = await bootstrapSession(server.baseUrl, { bootstrapSecret: "boot-secret" });
    assert.match(minted.sessionToken, /^st_/);
  } finally {
    await server.close();
  }
});

test("in production with no bootstrap secret configured, minting fails closed (500), not open", async () => {
  const server = await startTestServer({ nodeEnv: "production", bootstrapSecret: undefined });
  try {
    const res = await fetch(`${server.baseUrl}/v1/session`, { method: "POST" });
    assert.equal(res.status, 500);
    const body = await readJson<{ error: string }>(res);
    assert.equal(body.error, "bootstrap_secret_missing");
  } finally {
    await server.close();
  }
});

test("a minted token is not usable after it expires", async () => {
  const server = await startTestServer({ nodeEnv: "development", clientSessionTtlMs: 50 });
  try {
    const minted = await bootstrapSession(server.baseUrl);
    await new Promise((r) => setTimeout(r, 80));
    const res = await fetch(`${server.baseUrl}/v1/tasks`, {
      headers: { authorization: `Bearer ${minted.sessionToken}` },
    });
    assert.equal(res.status, 401);
  } finally {
    await server.close();
  }
});

test("session bootstrap is rate limited like every other /v1 route", async () => {
  const server = await startTestServer({ nodeEnv: "development", rateLimitMax: 2, rateLimitWindowMs: 60_000 });
  try {
    const statuses: number[] = [];
    for (let i = 0; i < 4; i++) {
      const res = await fetch(`${server.baseUrl}/v1/session`, { method: "POST" });
      statuses.push(res.status);
    }
    assert.ok(statuses.includes(429), `expected a 429 among ${JSON.stringify(statuses)}`);
  } finally {
    await server.close();
  }
});
