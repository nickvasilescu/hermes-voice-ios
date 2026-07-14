import { test } from "node:test";
import assert from "node:assert/strict";
import { startTestServer, startAuthedTestServer, bootstrapSession, authHeaders, readJson } from "./helpers.js";
import { MockHermesProvider } from "../src/hermes/mockProvider.js";

function waitUntil(predicate: () => Promise<boolean> | boolean, timeoutMs = 2000): Promise<void> {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    const tick = async () => {
      if (await predicate()) return resolve();
      if (Date.now() - start > timeoutMs) return reject(new Error("timed out"));
      setTimeout(tick, 10);
    };
    tick();
  });
}

test("POST /v1/tasks validates the body", async () => {
  const server = await startAuthedTestServer();
  try {
    const res = await fetch(`${server.baseUrl}/v1/tasks`, {
      method: "POST",
      headers: server.authHeaders(),
      body: JSON.stringify({}),
    });
    assert.equal(res.status, 400);
    const body = await readJson(res);
    assert.equal(body.error, "validation_error");
  } finally {
    await server.close();
  }
});

test("POST /v1/tasks rejects an instruction over the length limit", async () => {
  const server = await startAuthedTestServer();
  try {
    const res = await fetch(`${server.baseUrl}/v1/tasks`, {
      method: "POST",
      headers: server.authHeaders(),
      body: JSON.stringify({ instruction: "x".repeat(5000) }),
    });
    assert.equal(res.status, 400);
  } finally {
    await server.close();
  }
});

test("GET /v1/tasks/:taskId rejects a malformed taskId", async () => {
  const server = await startAuthedTestServer();
  try {
    const tooLong = await fetch(`${server.baseUrl}/v1/tasks/${"task_" + "x".repeat(200)}`, {
      headers: server.authHeaders(),
    });
    assert.equal(tooLong.status, 400);

    const invalidChars = await fetch(`${server.baseUrl}/v1/tasks/${encodeURIComponent("bad id!")}`, {
      headers: server.authHeaders(),
    });
    assert.equal(invalidChars.status, 400);
  } finally {
    await server.close();
  }
});

test("full task lifecycle: create, get, list, followup, and completion via SSE-observable state", async () => {
  const server = await startAuthedTestServer(
    {},
    { hermesProvider: new MockHermesProvider({ minDelayMs: 200, maxDelayMs: 260 }) }
  );
  try {
    const createRes = await fetch(`${server.baseUrl}/v1/tasks`, {
      method: "POST",
      headers: server.authHeaders(),
      body: JSON.stringify({ instruction: "book a table" }),
    });
    assert.equal(createRes.status, 201);
    const task = await readJson(createRes);
    assert.match(task.id, /^task_/);
    assert.equal(task.status, "queued");
    assert.equal(task.hermesSessionId, server.hermesSessionId);

    const getRes = await fetch(`${server.baseUrl}/v1/tasks/${task.id}`, { headers: server.authHeaders() });
    assert.equal(getRes.status, 200);

    const listRes = await fetch(`${server.baseUrl}/v1/tasks`, { headers: server.authHeaders() });
    const listed = await readJson(listRes);
    assert.equal(listed.tasks.length, 1);

    const followupRes = await fetch(`${server.baseUrl}/v1/tasks/${task.id}/followup`, {
      method: "POST",
      headers: server.authHeaders(),
      body: JSON.stringify({ message: "make it for 4pm" }),
    });
    assert.equal(followupRes.status, 200);

    await waitUntil(async () => {
      const r = await fetch(`${server.baseUrl}/v1/tasks/${task.id}`, { headers: server.authHeaders() });
      const t = await readJson(r);
      return t.status === "completed";
    });
  } finally {
    await server.close();
  }
});

test("GET /v1/tasks/:id 404s for unknown task or a different client session's hermesSessionId", async () => {
  const server = await startTestServer({}, { hermesProvider: new MockHermesProvider({ minDelayMs: 1, maxDelayMs: 5 }) });
  try {
    const sessionA = await bootstrapSession(server.baseUrl);
    const sessionB = await bootstrapSession(server.baseUrl);

    const createRes = await fetch(`${server.baseUrl}/v1/tasks`, {
      method: "POST",
      headers: authHeaders(sessionA.sessionToken),
      body: JSON.stringify({ instruction: "x" }),
    });
    const task = await readJson(createRes);

    const notFound = await fetch(`${server.baseUrl}/v1/tasks/task_bogus`, { headers: authHeaders(sessionA.sessionToken) });
    assert.equal(notFound.status, 404);

    const crossSession = await fetch(`${server.baseUrl}/v1/tasks/${task.id}`, {
      headers: authHeaders(sessionB.sessionToken),
    });
    assert.equal(crossSession.status, 404);
  } finally {
    await server.close();
  }
});

test("POST /v1/tasks/:id/cancel cancels a task; canceling again 409s", async () => {
  const server = await startAuthedTestServer(
    {},
    { hermesProvider: new MockHermesProvider({ minDelayMs: 40, maxDelayMs: 60 }) }
  );
  try {
    const createRes = await fetch(`${server.baseUrl}/v1/tasks`, {
      method: "POST",
      headers: server.authHeaders(),
      body: JSON.stringify({ instruction: "long task" }),
    });
    const task = await readJson(createRes);

    const cancelRes = await fetch(`${server.baseUrl}/v1/tasks/${task.id}/cancel`, {
      method: "POST",
      headers: server.authHeaders(),
      body: JSON.stringify({ reason: "nvm" }),
    });
    assert.equal(cancelRes.status, 200);
    const canceled = await readJson(cancelRes);
    assert.equal(canceled.status, "canceled");

    const secondCancel = await fetch(`${server.baseUrl}/v1/tasks/${task.id}/cancel`, {
      method: "POST",
      headers: server.authHeaders(),
      body: JSON.stringify({}),
    });
    assert.equal(secondCancel.status, 409);
  } finally {
    await server.close();
  }
});

test("approve flow: instruction containing 'approve' pauses, then approve resolves it", async () => {
  const server = await startAuthedTestServer(
    {},
    { hermesProvider: new MockHermesProvider({ minDelayMs: 1, maxDelayMs: 5 }) }
  );
  try {
    const createRes = await fetch(`${server.baseUrl}/v1/tasks`, {
      method: "POST",
      headers: server.authHeaders(),
      body: JSON.stringify({ instruction: "please approve this refund" }),
    });
    const task = await readJson(createRes);

    await waitUntil(async () => {
      const r = await fetch(`${server.baseUrl}/v1/tasks/${task.id}`, { headers: server.authHeaders() });
      const t = await readJson(r);
      return t.status === "waiting_approval";
    });

    const stateRes = await fetch(`${server.baseUrl}/v1/tasks/${task.id}`, { headers: server.authHeaders() });
    const state = await readJson(stateRes);
    const approvalId = state.pendingApproval.approvalId;

    const wrongDecision = await fetch(`${server.baseUrl}/v1/tasks/${task.id}/approve`, {
      method: "POST",
      headers: server.authHeaders(),
      body: JSON.stringify({ approvalId: "appr_wrong", decision: "approve" }),
    });
    assert.equal(wrongDecision.status, 409);

    const approveRes = await fetch(`${server.baseUrl}/v1/tasks/${task.id}/approve`, {
      method: "POST",
      headers: server.authHeaders(),
      body: JSON.stringify({ approvalId, decision: "approve" }),
    });
    assert.equal(approveRes.status, 200);

    await waitUntil(async () => {
      const r = await fetch(`${server.baseUrl}/v1/tasks/${task.id}`, { headers: server.authHeaders() });
      const t = await readJson(r);
      return t.status === "completed";
    });
  } finally {
    await server.close();
  }
});

test("clientRequestId makes POST /v1/tasks idempotent over HTTP: 201 on creation, 200 on replay", async () => {
  const server = await startAuthedTestServer(
    {},
    { hermesProvider: new MockHermesProvider({ minDelayMs: 1, maxDelayMs: 5 }) }
  );
  try {
    const body = JSON.stringify({ instruction: "x", clientRequestId: "req-1" });
    const first = await fetch(`${server.baseUrl}/v1/tasks`, { method: "POST", headers: server.authHeaders(), body });
    const second = await fetch(`${server.baseUrl}/v1/tasks`, { method: "POST", headers: server.authHeaders(), body });
    assert.equal(first.status, 201);
    assert.equal(second.status, 200);
    const firstTask = await readJson(first);
    const secondTask = await readJson(second);
    assert.equal(firstTask.id, secondTask.id);
  } finally {
    await server.close();
  }
});

test("GET /v1/health requires no auth or session header", async () => {
  const server = await startTestServer();
  try {
    const res = await fetch(`${server.baseUrl}/v1/health`);
    assert.equal(res.status, 200);
    const body = await readJson(res);
    assert.equal(body.ok, true);
  } finally {
    await server.close();
  }
});
