import { test } from "node:test";
import assert from "node:assert/strict";
import { startTestServer } from "./helpers.js";

// CORS headers are set by middleware that runs before auth, so these don't
// need a valid session token — only the Origin header and response headers
// are under test here, regardless of the eventual (401) status code.

test("an allowlisted origin gets Access-Control-Allow-Origin echoed back", async () => {
  const server = await startTestServer({ corsAllowlist: ["https://allowed.example"] });
  try {
    const res = await fetch(`${server.baseUrl}/v1/tasks`, {
      headers: { origin: "https://allowed.example" },
    });
    assert.equal(res.headers.get("access-control-allow-origin"), "https://allowed.example");
  } finally {
    await server.close();
  }
});

test("a non-allowlisted origin does not get the CORS header", async () => {
  const server = await startTestServer({ corsAllowlist: ["https://allowed.example"] });
  try {
    const res = await fetch(`${server.baseUrl}/v1/tasks`, {
      headers: { origin: "https://evil.example" },
    });
    assert.equal(res.headers.get("access-control-allow-origin"), null);
  } finally {
    await server.close();
  }
});

test("with an empty allowlist in development mode, any origin is reflected", async () => {
  const server = await startTestServer({ corsAllowlist: [], nodeEnv: "development" });
  try {
    const res = await fetch(`${server.baseUrl}/v1/tasks`, {
      headers: { origin: "https://anything.example" },
    });
    assert.equal(res.headers.get("access-control-allow-origin"), "https://anything.example");
  } finally {
    await server.close();
  }
});

test("with an empty allowlist in production mode, no origin is allowed", async () => {
  const server = await startTestServer({ corsAllowlist: [], nodeEnv: "production" });
  try {
    const res = await fetch(`${server.baseUrl}/v1/tasks`, {
      headers: { origin: "https://anything.example" },
    });
    assert.equal(res.headers.get("access-control-allow-origin"), null);
  } finally {
    await server.close();
  }
});
