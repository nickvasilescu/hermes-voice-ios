import { test } from "node:test";
import assert from "node:assert/strict";
import { ApiServerHermesProvider } from "../src/hermes/apiServerProvider.js";
import { HermesProviderError, type HermesProviderEvent } from "../src/hermes/provider.js";

function sseBody(chunks: unknown[]): ReadableStream<Uint8Array> {
  const encoder = new TextEncoder();
  const text = chunks.map((c) => `data: ${JSON.stringify(c)}\n\n`).join("") + ": stream closed\n\n";
  return new ReadableStream({
    start(controller) {
      controller.enqueue(encoder.encode(text));
      controller.close();
    },
  });
}

function collectEvents(provider: ApiServerHermesProvider): HermesProviderEvent[] {
  const events: HermesProviderEvent[] = [];
  provider.onEvent((e) => events.push(e));
  return events;
}

async function waitFor(
  events: HermesProviderEvent[],
  predicate: (e: HermesProviderEvent) => boolean,
  timeoutMs = 1000
): Promise<HermesProviderEvent> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const found = events.find(predicate);
    if (found) return found;
    await new Promise((r) => setTimeout(r, 10));
  }
  throw new Error(`Timed out waiting for event. Saw: ${JSON.stringify(events)}`);
}

test("ApiServerHermesProvider maps a simple run to completed", async () => {
  const runId = "run_abc";
  const fetchImpl: typeof fetch = async (input, init) => {
    const url = String(input);
    if (url.endsWith("/v1/runs") && init?.method === "POST") {
      const body = JSON.parse(String(init.body));
      assert.equal(body.input, "say hi");
      assert.equal(body.session_id, "sess_1");
      return new Response(JSON.stringify({ run_id: runId, status: "started" }), { status: 202 });
    }
    if (url.endsWith(`/v1/runs/${runId}/events`)) {
      return new Response(
        sseBody([
          { event: "tool.started", run_id: runId, tool: "terminal", preview: "echo hi" },
          { event: "run.completed", run_id: runId, output: "hello", usage: { total_tokens: 3 } },
        ]),
        { status: 200, headers: { "Content-Type": "text/event-stream" } }
      );
    }
    throw new Error(`Unexpected fetch ${init?.method} ${url}`);
  };

  const provider = new ApiServerHermesProvider({
    baseUrl: "http://hermes.test",
    apiKey: "secret",
    fetchImpl,
  });
  const events = collectEvents(provider);

  await provider.createTask({
    taskId: "task_1",
    hermesSessionId: "sess_1",
    instruction: "say hi",
  });

  await waitFor(events, (e) => e.type === "completed");
  assert.equal(events[0]?.type, "status");
  assert.ok(events.some((e) => e.type === "progress"));
  const completed = events.find((e) => e.type === "completed");
  assert.ok(completed && completed.type === "completed");
  assert.equal(completed.summary, "hello");
});

test("ApiServerHermesProvider queues follow-up until the current run completes", async () => {
  let runCount = 0;
  let releaseFirstRun!: () => void;
  const firstRunGate = new Promise<void>((resolve) => {
    releaseFirstRun = resolve;
  });

  const fetchImpl: typeof fetch = async (input, init) => {
    const url = String(input);
    if (url.endsWith("/v1/runs") && init?.method === "POST") {
      runCount += 1;
      const runId = `run_${runCount}`;
      const body = JSON.parse(String(init.body));
      if (runCount === 1) {
        assert.equal(body.input, "first");
        assert.equal(body.conversation_history, undefined);
      } else {
        assert.equal(body.input, "second");
        assert.deepEqual(body.conversation_history, [
          { role: "user", content: "first" },
          { role: "assistant", content: "one" },
        ]);
      }
      return new Response(JSON.stringify({ run_id: runId, status: "started" }), { status: 202 });
    }
    const eventsMatch = url.match(/\/v1\/runs\/(run_\d+)\/events$/);
    if (eventsMatch) {
      const runId = eventsMatch[1];
      if (runId === "run_1") {
        await firstRunGate;
        return new Response(sseBody([{ event: "run.completed", run_id: runId, output: "one" }]), {
          status: 200,
          headers: { "Content-Type": "text/event-stream" },
        });
      }
      return new Response(sseBody([{ event: "run.completed", run_id: runId, output: "two" }]), {
        status: 200,
        headers: { "Content-Type": "text/event-stream" },
      });
    }
    throw new Error(`Unexpected fetch ${init?.method} ${url}`);
  };

  const provider = new ApiServerHermesProvider({
    baseUrl: "http://hermes.test",
    apiKey: "secret",
    fetchImpl,
  });
  const events = collectEvents(provider);

  await provider.createTask({
    taskId: "task_follow",
    hermesSessionId: "sess_f",
    instruction: "first",
  });

  // Queue follow-up while the first run is still open.
  await provider.sendFollowup("task_follow", "second");
  releaseFirstRun();

  await waitFor(events, (e) => e.type === "completed" && e.summary === "two", 2000);
  assert.equal(runCount, 2);
  assert.ok(events.some((e) => e.type === "progress" && e.message.includes("Follow-up queued")));
});

test("ApiServerHermesProvider maps approval.request and resolveApproval", async () => {
  const runId = "run_appr";
  let approvalBody: unknown;
  const fetchImpl: typeof fetch = async (input, init) => {
    const url = String(input);
    if (url.endsWith("/v1/runs") && init?.method === "POST") {
      return new Response(JSON.stringify({ run_id: runId, status: "started" }), { status: 202 });
    }
    if (url.endsWith(`/v1/runs/${runId}/events`)) {
      // Keep the stream open until approval then complete — use a controller.
      const encoder = new TextEncoder();
      let controller: ReadableStreamDefaultController<Uint8Array>;
      const stream = new ReadableStream<Uint8Array>({
        start(c) {
          controller = c;
          controller.enqueue(
            encoder.encode(
              `data: ${JSON.stringify({
                event: "approval.request",
                run_id: runId,
                command: "rm -rf /tmp/x",
                choices: ["once", "deny"],
              })}\n\n`
            )
          );
          (fetchImpl as unknown as { _complete: () => void })._complete = () => {
            controller.enqueue(
              encoder.encode(
                `data: ${JSON.stringify({ event: "run.completed", run_id: runId, output: "ok" })}\n\n`
              )
            );
            controller.close();
          };
        },
      });
      return new Response(stream, { status: 200, headers: { "Content-Type": "text/event-stream" } });
    }
    if (url.endsWith(`/v1/runs/${runId}/approval`) && init?.method === "POST") {
      approvalBody = JSON.parse(String(init.body));
      (fetchImpl as unknown as { _complete: () => void })._complete();
      return new Response(JSON.stringify({ run_id: runId, choice: "once", resolved: 1 }), { status: 200 });
    }
    throw new Error(`Unexpected fetch ${init?.method} ${url}`);
  };

  const provider = new ApiServerHermesProvider({
    baseUrl: "http://hermes.test",
    apiKey: "secret",
    fetchImpl,
  });
  const events = collectEvents(provider);

  await provider.createTask({
    taskId: "task_appr",
    hermesSessionId: "sess_a",
    instruction: "do something gated",
  });

  const approval = await waitFor(events, (e) => e.type === "approval_required");
  assert.ok(approval.type === "approval_required");
  assert.match(approval.approvalId, /^appr_[0-9a-f-]{36}$/i);

  await provider.resolveApproval("task_appr", approval.approvalId, "approve");
  assert.deepEqual(approvalBody, { choice: "once" });
  await waitFor(events, (e) => e.type === "completed");
});

test("ApiServerHermesProvider fails the task when SSE closes without a terminal event", async () => {
  const runId = "run_eof";
  const fetchImpl: typeof fetch = async (input, init) => {
    const url = String(input);
    if (url.endsWith("/v1/runs") && init?.method === "POST") {
      return new Response(JSON.stringify({ run_id: runId, status: "started" }), { status: 202 });
    }
    if (url.endsWith(`/v1/runs/${runId}/events`)) {
      // Keepalive only — then clean EOF. Mimics an idle proxy closing the stream.
      return new Response(sseBody([]), {
        status: 200,
        headers: { "Content-Type": "text/event-stream" },
      });
    }
    throw new Error(`Unexpected fetch ${init?.method} ${url}`);
  };

  const provider = new ApiServerHermesProvider({
    baseUrl: "http://hermes.test",
    apiKey: "secret",
    fetchImpl,
  });
  const events = collectEvents(provider);

  await provider.createTask({
    taskId: "task_eof",
    hermesSessionId: "sess_eof",
    instruction: "long job",
  });

  const failed = await waitFor(events, (e) => e.type === "failed");
  assert.ok(failed.type === "failed");
  assert.equal(failed.error.code, "sse_closed_unexpectedly");
});

test("ApiServerHermesProvider cancel treats /stop 404 as already-gone", async () => {
  const runId = "run_gone";
  let stopped = false;
  const fetchImpl: typeof fetch = async (input, init) => {
    const url = String(input);
    if (url.endsWith("/v1/runs") && init?.method === "POST") {
      return new Response(JSON.stringify({ run_id: runId, status: "started" }), { status: 202 });
    }
    if (url.endsWith(`/v1/runs/${runId}/events`)) {
      const encoder = new TextEncoder();
      return new Response(
        new ReadableStream({
          start(controller) {
            controller.enqueue(encoder.encode(": keepalive\n\n"));
          },
          cancel() {},
        }),
        { status: 200, headers: { "Content-Type": "text/event-stream" } }
      );
    }
    if (url.endsWith(`/v1/runs/${runId}/stop`) && init?.method === "POST") {
      stopped = true;
      return new Response(JSON.stringify({ error: "not found" }), { status: 404 });
    }
    throw new Error(`Unexpected fetch ${init?.method} ${url}`);
  };

  const provider = new ApiServerHermesProvider({
    baseUrl: "http://hermes.test",
    apiKey: "secret",
    fetchImpl,
  });
  const events = collectEvents(provider);

  await provider.createTask({
    taskId: "task_gone",
    hermesSessionId: "sess_g",
    instruction: "maybe already done",
  });
  await waitFor(events, (e) => e.type === "status");
  await provider.cancelTask("task_gone");
  assert.equal(stopped, true);
  assert.ok(events.some((e) => e.type === "canceled"));
});

test("ApiServerHermesProvider stops an orphaned run when cancel wins during startup", async () => {
  const runId = "run_orphan";
  let releaseCreate!: () => void;
  const createGate = new Promise<void>((resolve) => {
    releaseCreate = resolve;
  });
  let stoppedRunId: string | undefined;
  let eventsAttached = false;

  const fetchImpl: typeof fetch = async (input, init) => {
    const url = String(input);
    if (url.endsWith("/v1/runs") && init?.method === "POST") {
      await createGate;
      return new Response(JSON.stringify({ run_id: runId, status: "started" }), { status: 202 });
    }
    if (url.endsWith(`/v1/runs/${runId}/events`)) {
      eventsAttached = true;
      return new Response(sseBody([{ event: "run.completed", run_id: runId, output: "should not matter" }]), {
        status: 200,
        headers: { "Content-Type": "text/event-stream" },
      });
    }
    if (url.endsWith(`/v1/runs/${runId}/stop`) && init?.method === "POST") {
      stoppedRunId = runId;
      return new Response(JSON.stringify({ run_id: runId, status: "stopping" }), { status: 200 });
    }
    throw new Error(`Unexpected fetch ${init?.method} ${url}`);
  };

  const provider = new ApiServerHermesProvider({
    baseUrl: "http://hermes.test",
    apiKey: "secret",
    fetchImpl,
  });
  const events = collectEvents(provider);

  const createPromise = provider.createTask({
    taskId: "task_orphan",
    hermesSessionId: "sess_o",
    instruction: "slow start",
  });
  // Let createTask reach startingRun + await on POST /v1/runs.
  await new Promise((r) => setTimeout(r, 20));
  await provider.cancelTask("task_orphan");
  releaseCreate();
  await createPromise;

  assert.equal(stoppedRunId, runId);
  assert.equal(eventsAttached, false);
  assert.ok(events.some((e) => e.type === "canceled"));
});

test("ApiServerHermesProvider fails the task if follow-up drain throws after run.completed", async () => {
  let runCount = 0;
  let releaseFirstRun!: () => void;
  const firstRunGate = new Promise<void>((resolve) => {
    releaseFirstRun = resolve;
  });

  const fetchImpl: typeof fetch = async (input, init) => {
    const url = String(input);
    if (url.endsWith("/v1/runs") && init?.method === "POST") {
      runCount += 1;
      if (runCount === 2) {
        return new Response(JSON.stringify({ error: "hermes unreachable" }), { status: 503 });
      }
      return new Response(JSON.stringify({ run_id: `run_${runCount}`, status: "started" }), { status: 202 });
    }
    const eventsMatch = url.match(/\/v1\/runs\/(run_\d+)\/events$/);
    if (eventsMatch) {
      const runId = eventsMatch[1];
      if (runId === "run_1") {
        await firstRunGate;
        return new Response(sseBody([{ event: "run.completed", run_id: runId, output: "one" }]), {
          status: 200,
          headers: { "Content-Type": "text/event-stream" },
        });
      }
      throw new Error(`Unexpected events fetch for ${runId}`);
    }
    throw new Error(`Unexpected fetch ${init?.method} ${url}`);
  };

  const provider = new ApiServerHermesProvider({
    baseUrl: "http://hermes.test",
    apiKey: "secret",
    fetchImpl,
  });
  const events = collectEvents(provider);

  await provider.createTask({
    taskId: "task_drain_fail",
    hermesSessionId: "sess_df",
    instruction: "first",
  });
  // Queue while first run is still open so afterRunSettled (not sendFollowup) drains it.
  await provider.sendFollowup("task_drain_fail", "second");
  releaseFirstRun();

  const failed = await waitFor(events, (e) => e.type === "failed", 2000);
  assert.ok(failed.type === "failed");
  assert.ok(runCount >= 2);
});
test("ApiServerHermesProvider cancelTask posts /stop and emits canceled", async () => {
  const runId = "run_stop";
  let stopped = false;
  const fetchImpl: typeof fetch = async (input, init) => {
    const url = String(input);
    if (url.endsWith("/v1/runs") && init?.method === "POST") {
      return new Response(JSON.stringify({ run_id: runId, status: "started" }), { status: 202 });
    }
    if (url.endsWith(`/v1/runs/${runId}/events`)) {
      const encoder = new TextEncoder();
      return new Response(
        new ReadableStream({
          start(controller) {
            // Never completes on its own.
            controller.enqueue(encoder.encode(": keepalive\n\n"));
          },
          cancel() {}
        }),
        { status: 200, headers: { "Content-Type": "text/event-stream" } }
      );
    }
    if (url.endsWith(`/v1/runs/${runId}/stop`) && init?.method === "POST") {
      stopped = true;
      return new Response(JSON.stringify({ run_id: runId, status: "stopping" }), { status: 200 });
    }
    throw new Error(`Unexpected fetch ${init?.method} ${url}`);
  };

  const provider = new ApiServerHermesProvider({
    baseUrl: "http://hermes.test",
    apiKey: "secret",
    fetchImpl,
  });
  const events = collectEvents(provider);

  await provider.createTask({
    taskId: "task_stop",
    hermesSessionId: "sess_s",
    instruction: "long job",
  });
  await waitFor(events, (e) => e.type === "status");
  await provider.cancelTask("task_stop");
  assert.equal(stopped, true);
  assert.ok(events.some((e) => e.type === "canceled"));
  await assert.rejects(() => provider.cancelTask("task_stop"), (err: unknown) => {
    assert.ok(err instanceof HermesProviderError);
    assert.equal(err.code, "task_terminal");
    return true;
  });
});
