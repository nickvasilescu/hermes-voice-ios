import { test } from "node:test";
import assert from "node:assert/strict";
import { redact } from "../src/logger.js";

test("redact masks known sensitive keys at any depth", () => {
  const input = {
    hermesSessionId: "sess_1",
    authorization: "Bearer abc123",
    clientSecret: { value: "ek_verysecret", expiresAt: "2026-01-01T00:00:00Z" },
    nested: { apiKey: "sk-verysecret", ok: true },
  };
  const output = redact(input) as Record<string, unknown>;

  assert.equal(output.hermesSessionId, "sess_1");
  assert.equal(output.authorization, "[REDACTED]");
  assert.equal((output.clientSecret as Record<string, unknown>).value, "[REDACTED]");
  assert.equal((output.clientSecret as Record<string, unknown>).expiresAt, "2026-01-01T00:00:00Z");
  assert.equal((output.nested as Record<string, unknown>).apiKey, "[REDACTED]");
  assert.equal((output.nested as Record<string, unknown>).ok, true);
});

test("redact handles arrays and leaves primitives and non-sensitive keys untouched", () => {
  const input = { items: [{ apiKey: "x" }, { fine: "y" }], count: 2 };
  const output = redact(input) as Record<string, unknown>;
  const items = output.items as Array<Record<string, unknown>>;
  assert.equal(items[0]?.apiKey, "[REDACTED]");
  assert.equal(items[1]?.fine, "y");
  assert.equal(output.count, 2);
});

test("redact is case-insensitive on key names", () => {
  const input = { Authorization: "Bearer abc", ApiKey: "x" };
  const output = redact(input) as Record<string, unknown>;
  assert.equal(output.Authorization, "[REDACTED]");
  assert.equal(output.ApiKey, "[REDACTED]");
});

test("redact does not choke on null, undefined, or primitives", () => {
  assert.equal(redact(null), null);
  assert.equal(redact(undefined), undefined);
  assert.equal(redact("plain"), "plain");
  assert.equal(redact(42), 42);
});
