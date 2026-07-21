import { test } from "node:test";
import assert from "node:assert/strict";
import { startTestServer, startAuthedTestServer, readJson } from "./helpers.js";

test("protected routes reject requests with no Authorization header", async () => {
  const server = await startTestServer();
  try {
    const res = await fetch(`${server.baseUrl}/v1/tasks`);
    assert.equal(res.status, 401);
    const body = await readJson<{ error: string }>(res);
    assert.equal(body.error, "missing_session_token");
  } finally {
    await server.close();
  }
});

test("protected routes reject a well-formed but unknown session token", async () => {
  const server = await startTestServer();
  try {
    const res = await fetch(`${server.baseUrl}/v1/tasks`, {
      headers: { authorization: "Bearer st_not_a_real_token" },
    });
    assert.equal(res.status, 401);
    const body = await readJson<{ error: string }>(res);
    assert.equal(body.error, "invalid_session");
  } finally {
    await server.close();
  }
});

test("protected routes reject a non-Bearer Authorization header", async () => {
  const server = await startTestServer();
  try {
    const res = await fetch(`${server.baseUrl}/v1/tasks`, { headers: { authorization: "Basic dXNlcjpwYXNz" } });
    assert.equal(res.status, 401);
  } finally {
    await server.close();
  }
});

test("a validly minted session token is accepted on protected routes", async () => {
  const server = await startAuthedTestServer();
  try {
    const res = await fetch(`${server.baseUrl}/v1/tasks`, { headers: server.authHeaders() });
    assert.equal(res.status, 200);
  } finally {
    await server.close();
  }
});

test("task ownership and Hermes thread ids are server-selected, not client-supplied", async () => {
  const server = await startAuthedTestServer();
  try {
    const createRes = await fetch(`${server.baseUrl}/v1/tasks`, {
      method: "POST",
      headers: server.authHeaders(),
      body: JSON.stringify({
        instruction: "x",
        hermesSessionId: "hs_attacker",
        hermesThreadId: "ht_attacker",
      }),
    });
    const task = await readJson<{ hermesSessionId: string; hermesThreadId: string }>(createRes);
    assert.equal(task.hermesSessionId, server.hermesSessionId);
    assert.match(task.hermesThreadId, /^ht_[0-9a-f-]{36}$/i);
    assert.notEqual(task.hermesThreadId, "ht_attacker");
  } finally {
    await server.close();
  }
});

test("GET /v1/health never requires a session token", async () => {
  const server = await startTestServer({ bootstrapSecret: "irrelevant-here" });
  try {
    const res = await fetch(`${server.baseUrl}/v1/health`);
    assert.equal(res.status, 200);
  } finally {
    await server.close();
  }
});
