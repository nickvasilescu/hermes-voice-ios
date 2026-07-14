import { test } from "node:test";
import assert from "node:assert/strict";
import { startTestServer, startAuthedTestServer, bootstrapSession, authHeaders, readJson } from "./helpers.js";
import { MockHermesProvider } from "../src/hermes/mockProvider.js";

interface ParsedEvent {
  event: string;
  data: string;
}

function parseSSE(chunk: string): ParsedEvent[] {
  return chunk
    .split("\n\n")
    .filter((block) => block.trim().length > 0)
    .map((block) => {
      const lines = block.split("\n");
      const eventLine = lines.find((l) => l.startsWith("event:"));
      const dataLine = lines.find((l) => l.startsWith("data:"));
      return {
        event: eventLine?.slice("event:".length).trim() ?? "",
        data: dataLine?.slice("data:".length).trim() ?? "",
      };
    });
}

test("GET /v1/events streams task lifecycle events for the caller's hermesSessionId", async () => {
  const server = await startAuthedTestServer(
    {},
    { hermesProvider: new MockHermesProvider({ minDelayMs: 1, maxDelayMs: 5 }) }
  );
  const controller = new AbortController();
  try {
    const streamRes = await fetch(`${server.baseUrl}/v1/events`, {
      headers: server.authHeaders(),
      signal: controller.signal,
    });
    assert.equal(streamRes.status, 200);
    assert.match(streamRes.headers.get("content-type") ?? "", /text\/event-stream/);

    const reader = streamRes.body?.getReader();
    assert.ok(reader);
    const decoder = new TextDecoder();
    const seen: ParsedEvent[] = [];

    const createRes = await fetch(`${server.baseUrl}/v1/tasks`, {
      method: "POST",
      headers: server.authHeaders(),
      body: JSON.stringify({ instruction: "stream me" }),
    });
    const task = await readJson(createRes);

    const deadline = Date.now() + 3000;
    while (Date.now() < deadline) {
      const { value, done } = await reader.read();
      if (done) break;
      seen.push(...parseSSE(decoder.decode(value, { stream: true })));
      if (seen.some((e) => e.event === "task.completed")) break;
    }

    assert.ok(seen.some((e) => e.event === "task.created" && JSON.parse(e.data).id === task.id));
    assert.ok(seen.some((e) => e.event === "task.completed"));
  } finally {
    controller.abort();
    await server.close();
  }
});

test("GET /v1/events only delivers events for the requesting client session's hermesSessionId", async () => {
  const server = await startTestServer({}, { hermesProvider: new MockHermesProvider({ minDelayMs: 1, maxDelayMs: 5 }) });
  const controller = new AbortController();
  try {
    const isolated = await bootstrapSession(server.baseUrl);
    const other = await bootstrapSession(server.baseUrl);

    const streamRes = await fetch(`${server.baseUrl}/v1/events`, {
      headers: authHeaders(isolated.sessionToken),
      signal: controller.signal,
    });
    const reader = streamRes.body?.getReader();
    assert.ok(reader);
    const decoder = new TextDecoder();
    const seen: ParsedEvent[] = [];

    await fetch(`${server.baseUrl}/v1/tasks`, {
      method: "POST",
      headers: authHeaders(other.sessionToken),
      body: JSON.stringify({ instruction: "not for you" }),
    });

    const readOnce = async () => {
      const { value, done } = await Promise.race([
        reader.read(),
        new Promise<{ value: undefined; done: false }>((resolve) =>
          setTimeout(() => resolve({ value: undefined, done: false }), 200)
        ),
      ]);
      if (value) seen.push(...parseSSE(decoder.decode(value, { stream: true })));
      return done;
    };
    await readOnce();

    assert.equal(seen.length, 0);
  } finally {
    controller.abort();
    await server.close();
  }
});

test("GET /v1/events requires a valid client session token", async () => {
  const server = await startTestServer();
  try {
    const res = await fetch(`${server.baseUrl}/v1/events`);
    assert.equal(res.status, 401);
  } finally {
    await server.close();
  }
});
