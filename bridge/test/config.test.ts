import { test } from "node:test";
import assert from "node:assert/strict";
import { loadConfig } from "../src/config.js";

test("loadConfig applies sane defaults with an empty environment", () => {
  const config = loadConfig({});
  assert.equal(config.nodeEnv, "development");
  assert.equal(config.host, "127.0.0.1");
  assert.equal(config.port, 8787);
  assert.equal(config.mockOpenAI, false);
  assert.deepEqual(config.corsAllowlist, []);
  assert.equal(config.rateLimitMax, 60);
  assert.equal(config.rateLimitWindowMs, 60_000);
  assert.equal(config.ssePingMs, 15_000);
  assert.equal(config.realtimeModel, "gpt-realtime-2.1");
  assert.equal(config.bootstrapSecret, undefined);
  assert.equal(config.clientSessionTtlMs, 24 * 60 * 60 * 1000);
  assert.equal(config.clientSessionMaxEntries, 10_000);
  assert.equal(config.taskTtlMs, 24 * 60 * 60 * 1000);
  assert.equal(config.taskMaxEntries, 5000);
  assert.equal(config.idempotencyTtlMs, 24 * 60 * 60 * 1000);
  assert.equal(config.idempotencyMaxEntries, 5000);
  assert.equal(config.rateLimitMaxEntries, 5000);
});

test("loadConfig parses a comma-separated CORS allowlist and trims whitespace", () => {
  const config = loadConfig({ BRIDGE_CORS_ALLOWLIST: "https://a.example, https://b.example ,https://c.example" });
  assert.deepEqual(config.corsAllowlist, [
    "https://a.example",
    "https://b.example",
    "https://c.example",
  ]);
});

test("loadConfig reads BRIDGE_MOCK_OPENAI as a boolean flag", () => {
  assert.equal(loadConfig({ BRIDGE_MOCK_OPENAI: "1" }).mockOpenAI, true);
  assert.equal(loadConfig({ BRIDGE_MOCK_OPENAI: "true" }).mockOpenAI, true);
  assert.equal(loadConfig({ BRIDGE_MOCK_OPENAI: "0" }).mockOpenAI, false);
  assert.equal(loadConfig({}).mockOpenAI, false);
});

test("loadConfig parses numeric overrides", () => {
  const config = loadConfig({
    PORT: "9090",
    BRIDGE_RATE_LIMIT_MAX: "10",
    BRIDGE_RATE_LIMIT_WINDOW_MS: "5000",
    BRIDGE_SSE_PING_MS: "2000",
  });
  assert.equal(config.port, 9090);
  assert.equal(config.rateLimitMax, 10);
  assert.equal(config.rateLimitWindowMs, 5000);
  assert.equal(config.ssePingMs, 2000);
});

test("loadConfig accepts an explicit listen host", () => {
  assert.equal(loadConfig({ HOST: " 0.0.0.0 " }).host, "0.0.0.0");
});

test("loadConfig throws on a non-numeric PORT", () => {
  assert.throws(() => loadConfig({ PORT: "not-a-number" }));
});

test("loadConfig passes through OPENAI_API_KEY and BRIDGE_BOOTSTRAP_SECRET without transformation", () => {
  const config = loadConfig({ OPENAI_API_KEY: "sk-test", BRIDGE_BOOTSTRAP_SECRET: "bootstrap-secret" });
  assert.equal(config.openaiApiKey, "sk-test");
  assert.equal(config.bootstrapSecret, "bootstrap-secret");
});

test("loadConfig parses session/task/idempotency TTL and cap overrides", () => {
  const config = loadConfig({
    BRIDGE_SESSION_TTL_MS: "1000",
    BRIDGE_SESSION_MAX_ENTRIES: "10",
    BRIDGE_TASK_TTL_MS: "2000",
    BRIDGE_TASK_MAX_ENTRIES: "20",
    BRIDGE_IDEMPOTENCY_TTL_MS: "3000",
    BRIDGE_IDEMPOTENCY_MAX_ENTRIES: "30",
    BRIDGE_RATE_LIMIT_MAX_ENTRIES: "40",
  });
  assert.equal(config.clientSessionTtlMs, 1000);
  assert.equal(config.clientSessionMaxEntries, 10);
  assert.equal(config.taskTtlMs, 2000);
  assert.equal(config.taskMaxEntries, 20);
  assert.equal(config.idempotencyTtlMs, 3000);
  assert.equal(config.idempotencyMaxEntries, 30);
  assert.equal(config.rateLimitMaxEntries, 40);
  assert.equal(config.hermesApiBaseUrl, undefined);
  assert.equal(config.hermesApiKey, undefined);
});

test("loadConfig reads Hermes API Server settings", () => {
  const config = loadConfig({
    HERMES_API_BASE_URL: " http://127.0.0.1:8642/ ",
    HERMES_API_KEY: " secret ",
    HERMES_API_INSTRUCTIONS: " be brief ",
  });
  assert.equal(config.hermesApiBaseUrl, "http://127.0.0.1:8642/");
  assert.equal(config.hermesApiKey, "secret");
  assert.equal(config.hermesApiInstructions, "be brief");
});
