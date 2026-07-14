import { test } from "node:test";
import assert from "node:assert/strict";
import { startAuthedTestServer, readJson } from "./helpers.js";

// Bootstrapping a session (POST /v1/session) shares the same per-IP rate
// limit bucket as every other /v1 route, and startAuthedTestServer performs
// exactly one such bootstrap call — accounted for in each budget below.

test("requests beyond the configured limit within the window get 429", async () => {
  const server = await startAuthedTestServer({ rateLimitMax: 3, rateLimitWindowMs: 60_000 });
  try {
    const statuses: number[] = [];
    for (let i = 0; i < 5; i++) {
      const res = await fetch(`${server.baseUrl}/v1/tasks`, { headers: server.authHeaders() });
      statuses.push(res.status);
    }
    // budget 3, 1 already spent on bootstrap -> 2 more succeed, then 429s
    assert.deepEqual(statuses, [200, 200, 429, 429, 429]);
  } finally {
    await server.close();
  }
});

test("a 429 response includes retryAfterMs", async () => {
  const server = await startAuthedTestServer({ rateLimitMax: 2, rateLimitWindowMs: 60_000 });
  try {
    await fetch(`${server.baseUrl}/v1/tasks`, { headers: server.authHeaders() });
    const res = await fetch(`${server.baseUrl}/v1/tasks`, { headers: server.authHeaders() });
    assert.equal(res.status, 429);
    const body = await readJson(res);
    assert.equal(body.error, "rate_limited");
    assert.equal(typeof body.retryAfterMs, "number");
  } finally {
    await server.close();
  }
});

test("the limit resets after the window elapses", async () => {
  const server = await startAuthedTestServer({ rateLimitMax: 2, rateLimitWindowMs: 50 });
  try {
    const first = await fetch(`${server.baseUrl}/v1/tasks`, { headers: server.authHeaders() });
    assert.equal(first.status, 200);
    const blocked = await fetch(`${server.baseUrl}/v1/tasks`, { headers: server.authHeaders() });
    assert.equal(blocked.status, 429);

    await new Promise((r) => setTimeout(r, 70));
    const afterReset = await fetch(`${server.baseUrl}/v1/tasks`, { headers: server.authHeaders() });
    assert.equal(afterReset.status, 200);
  } finally {
    await server.close();
  }
});

test("GET /v1/health is exempt from rate limiting", async () => {
  const server = await startAuthedTestServer({ rateLimitMax: 1, rateLimitWindowMs: 60_000 });
  try {
    for (let i = 0; i < 5; i++) {
      const res = await fetch(`${server.baseUrl}/v1/health`);
      assert.equal(res.status, 200);
    }
  } finally {
    await server.close();
  }
});
