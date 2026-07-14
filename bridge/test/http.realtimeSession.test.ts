import { test } from "node:test";
import assert from "node:assert/strict";
import { startAuthedTestServer, readJson } from "./helpers.js";

function fakeOpenAIFetch(responseBody: unknown, status = 200) {
  const calls: Array<{ url: string; init: RequestInit }> = [];
  const fetchImpl = (async (url: string | URL, init?: RequestInit) => {
    calls.push({ url: String(url), init: init ?? {} });
    return new Response(JSON.stringify(responseBody), {
      status,
      headers: { "content-type": "application/json" },
    });
  }) as typeof fetch;
  return { fetchImpl, calls };
}

test("POST /v1/realtime/session mints a session using the configured OpenAI key and maps the response", async () => {
  const { fetchImpl, calls } = fakeOpenAIFetch({
    value: "ek_abc123",
    expires_at: Math.floor(Date.now() / 1000) + 3600,
    session: { id: "sess_openai_123" },
  });
  const server = await startAuthedTestServer({ openaiApiKey: "sk-test-key" }, { fetchImpl });
  try {
    const res = await fetch(`${server.baseUrl}/v1/realtime/session`, {
      method: "POST",
      headers: server.authHeaders(),
      body: JSON.stringify({ voice: "marin" }),
    });
    assert.equal(res.status, 200);
    const body = await readJson(res);
    assert.equal(body.model, "gpt-realtime-2.1");
    assert.equal(body.clientSecret.value, "ek_abc123");
    assert.equal(body.sessionId, "sess_openai_123");
    assert.equal(typeof body.expiresInSeconds, "number");

    assert.equal(calls.length, 1);
    assert.equal(calls[0]?.url, "https://api.openai.com/v1/realtime/client_secrets");
    const sentAuth = (calls[0]?.init.headers as Record<string, string>)?.["Authorization"];
    assert.equal(sentAuth, "Bearer sk-test-key");
    const sentBody = JSON.parse(String(calls[0]?.init.body));
    assert.equal(sentBody.session.model, "gpt-realtime-2.1");
    assert.equal(sentBody.session.audio.output.voice, "marin");
  } finally {
    await server.close();
  }
});

test("POST /v1/realtime/session returns 502 when the upstream call fails", async () => {
  const { fetchImpl } = fakeOpenAIFetch({ error: "boom" }, 500);
  const server = await startAuthedTestServer({ openaiApiKey: "sk-test-key" }, { fetchImpl });
  try {
    const res = await fetch(`${server.baseUrl}/v1/realtime/session`, {
      method: "POST",
      headers: server.authHeaders(),
      body: JSON.stringify({}),
    });
    assert.equal(res.status, 502);
    const body = await readJson(res);
    assert.equal(body.error, "upstream_error");
  } finally {
    await server.close();
  }
});

test("POST /v1/realtime/session returns 500 when no API key is configured and mock mode is off", async () => {
  const server = await startAuthedTestServer({ openaiApiKey: undefined, mockOpenAI: false });
  try {
    const res = await fetch(`${server.baseUrl}/v1/realtime/session`, {
      method: "POST",
      headers: server.authHeaders(),
      body: JSON.stringify({}),
    });
    assert.equal(res.status, 500);
    const body = await readJson(res);
    assert.equal(body.error, "openai_api_key_missing");
  } finally {
    await server.close();
  }
});

test("POST /v1/realtime/session returns an obviously-fake credential in mock mode", async () => {
  const server = await startAuthedTestServer({ openaiApiKey: undefined, mockOpenAI: true });
  try {
    const res = await fetch(`${server.baseUrl}/v1/realtime/session`, {
      method: "POST",
      headers: server.authHeaders(),
      body: JSON.stringify({}),
    });
    assert.equal(res.status, 200);
    const body = await readJson(res);
    assert.match(body.clientSecret.value, /^mock_ek_/);
  } finally {
    await server.close();
  }
});

test("POST /v1/realtime/session rejects without a valid client session token", async () => {
  const server = await startAuthedTestServer({ openaiApiKey: undefined, mockOpenAI: true });
  try {
    const res = await fetch(`${server.baseUrl}/v1/realtime/session`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({}),
    });
    assert.equal(res.status, 401);
  } finally {
    await server.close();
  }
});

for (const [name, payload] of [
  ["missing expiry", { value: "ek_test", session: { id: "sess_test" } }],
  ["invalid expiry", { value: "ek_test", expires_at: "not-a-date", session: { id: "sess_test" } }],
  ["expired credential", { value: "ek_test", expires_at: 1, session: { id: "sess_test" } }],
  ["missing session id", { value: "ek_test", expires_at: Math.floor(Date.now() / 1000) + 3600 }],
] as const) {
  test(`POST /v1/realtime/session rejects malformed upstream response: ${name}`, async () => {
    const { fetchImpl } = fakeOpenAIFetch(payload);
    const server = await startAuthedTestServer({ openaiApiKey: ["sk", "test", "key"].join("-") }, { fetchImpl });
    try {
      const res = await fetch(`${server.baseUrl}/v1/realtime/session`, {
        method: "POST",
        headers: server.authHeaders(),
        body: JSON.stringify({}),
      });
      assert.equal(res.status, 502);
      const body = await readJson(res);
      assert.equal(body.error, "upstream_error");
    } finally {
      await server.close();
    }
  });
}
