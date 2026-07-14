import { test } from "node:test";
import assert from "node:assert/strict";
import { MockHermesProvider } from "../src/hermes/mockProvider.js";
import { HermesProviderError } from "../src/hermes/provider.js";
import type { HermesProviderEvent } from "../src/hermes/provider.js";

function collector() {
  const events: HermesProviderEvent[] = [];
  const waiters: Array<{ predicate: (e: HermesProviderEvent[]) => boolean; resolve: () => void }> = [];
  const listener = (e: HermesProviderEvent) => {
    events.push(e);
    for (const w of [...waiters]) {
      if (w.predicate(events)) {
        w.resolve();
        waiters.splice(waiters.indexOf(w), 1);
      }
    }
  };
  const until = (predicate: (e: HermesProviderEvent[]) => boolean, timeoutMs = 2000) =>
    new Promise<void>((resolve, reject) => {
      if (predicate(events)) return resolve();
      const timer = setTimeout(() => reject(new Error("timed out waiting for events: " + JSON.stringify(events))), timeoutMs);
      waiters.push({
        predicate,
        resolve: () => {
          clearTimeout(timer);
          resolve();
        },
      });
    });
  return { events, listener, until };
}

test("MockHermesProvider runs a normal task to completion", async () => {
  const provider = new MockHermesProvider({ minDelayMs: 1, maxDelayMs: 5 });
  const { events, listener, until } = collector();
  provider.onEvent(listener);

  await provider.createTask({
    taskId: "task_1",
    hermesSessionId: "sess_1",
    instruction: "book a table for two",
  });

  await until((e) => e.some((ev) => ev.type === "completed"));

  const kinds = events.map((e) => e.type);
  assert.deepEqual(kinds, ["status", "progress", "completed"]);
  const completed = events.find((e) => e.type === "completed");
  assert.equal(completed?.type, "completed");
});

test("MockHermesProvider pauses for approval when instruction mentions approve", async () => {
  const provider = new MockHermesProvider({ minDelayMs: 1, maxDelayMs: 5 });
  const { events, listener, until } = collector();
  provider.onEvent(listener);

  await provider.createTask({
    taskId: "task_2",
    hermesSessionId: "sess_1",
    instruction: "please approve a $40 refund",
  });

  await until((e) => e.some((ev) => ev.type === "approval_required"));
  const approvalEvent = events.find((e) => e.type === "approval_required");
  assert.equal(approvalEvent?.type, "approval_required");
  if (approvalEvent?.type !== "approval_required") throw new Error("unreachable");
  assert.ok(approvalEvent.approvalId.startsWith("appr_"));

  await provider.resolveApproval("task_2", approvalEvent.approvalId, "approve");
  await until((e) => e.some((ev) => ev.type === "completed"));
  assert.ok(events.some((e) => e.type === "completed"));
});

test("MockHermesProvider fails the task when an approval is rejected", async () => {
  const provider = new MockHermesProvider({ minDelayMs: 1, maxDelayMs: 5 });
  const { events, listener, until } = collector();
  provider.onEvent(listener);

  await provider.createTask({
    taskId: "task_3",
    hermesSessionId: "sess_1",
    instruction: "approve this please",
  });
  await until((e) => e.some((ev) => ev.type === "approval_required"));
  const approvalEvent = events.find((e) => e.type === "approval_required");
  if (approvalEvent?.type !== "approval_required") throw new Error("unreachable");

  await provider.resolveApproval("task_3", approvalEvent.approvalId, "reject");
  await until((e) => e.some((ev) => ev.type === "failed"));
  const failed = events.find((e) => e.type === "failed");
  assert.equal(failed?.type, "failed");
  if (failed?.type !== "failed") throw new Error("unreachable");
  assert.equal(failed.error.code, "approval_rejected");
});

test("MockHermesProvider rejects resolveApproval with a mismatched approvalId", async () => {
  const provider = new MockHermesProvider({ minDelayMs: 1, maxDelayMs: 5 });
  const { listener, until } = collector();
  provider.onEvent(listener);

  await provider.createTask({
    taskId: "task_4",
    hermesSessionId: "sess_1",
    instruction: "approve it",
  });
  await until((e) => e.some((ev) => ev.type === "approval_required"));

  await assert.rejects(
    () => provider.resolveApproval("task_4", "appr_wrong", "approve"),
    (err: unknown) => err instanceof HermesProviderError && err.code === "no_matching_approval"
  );
});

test("MockHermesProvider cancelTask stops further events", async () => {
  const provider = new MockHermesProvider({ minDelayMs: 20, maxDelayMs: 30 });
  const { events, listener } = collector();
  provider.onEvent(listener);

  await provider.createTask({
    taskId: "task_5",
    hermesSessionId: "sess_1",
    instruction: "long running task",
  });
  await provider.cancelTask("task_5", "user changed their mind");

  await new Promise((r) => setTimeout(r, 80));
  assert.ok(!events.some((e) => e.type === "completed"));
  assert.ok(!events.some((e) => e.type === "progress"));
});

test("MockHermesProvider cancelTask on an already-terminal task throws", async () => {
  const provider = new MockHermesProvider({ minDelayMs: 1, maxDelayMs: 5 });
  const { listener, until } = collector();
  provider.onEvent(listener);

  await provider.createTask({
    taskId: "task_6",
    hermesSessionId: "sess_1",
    instruction: "quick task",
  });
  await until((e) => e.some((ev) => ev.type === "completed"));

  await assert.rejects(
    () => provider.cancelTask("task_6"),
    (err: unknown) => err instanceof HermesProviderError && err.code === "task_terminal"
  );
});

test("MockHermesProvider sendFollowup on unknown task throws task_not_found", async () => {
  const provider = new MockHermesProvider({ minDelayMs: 1, maxDelayMs: 5 });
  await assert.rejects(
    () => provider.sendFollowup("task_does_not_exist", "hello"),
    (err: unknown) => err instanceof HermesProviderError && err.code === "task_not_found"
  );
});

test("MockHermesProvider bounds its internal task records: oldest is evicted past maxEntries", async () => {
  const provider = new MockHermesProvider({ minDelayMs: 10_000, maxDelayMs: 10_000, maxEntries: 2 });

  await provider.createTask({ taskId: "task_old", hermesSessionId: "sess_1", instruction: "a" });
  await provider.createTask({ taskId: "task_mid", hermesSessionId: "sess_1", instruction: "b" });
  await provider.createTask({ taskId: "task_new", hermesSessionId: "sess_1", instruction: "c" });

  // task_old should have been evicted once the third task pushed the
  // internal store past maxEntries: 2.
  await assert.rejects(
    () => provider.cancelTask("task_old"),
    (err: unknown) => err instanceof HermesProviderError && err.code === "task_not_found"
  );
  // task_new is still tracked and cancelable.
  await provider.cancelTask("task_new");
});

test("MockHermesProvider proactively cleans up terminal tasks after terminalRetentionMs", async () => {
  const provider = new MockHermesProvider({ minDelayMs: 1, maxDelayMs: 5, terminalRetentionMs: 20 });
  const { events, listener, until } = collector();
  provider.onEvent(listener);

  await provider.createTask({ taskId: "task_done", hermesSessionId: "sess_1", instruction: "quick task" });
  await until((e) => e.some((ev) => ev.type === "completed"));

  // Immediately after completion the record is still around — a
  // near-simultaneous call gets a clear task_terminal.
  await assert.rejects(
    () => provider.cancelTask("task_done"),
    (err: unknown) => err instanceof HermesProviderError && err.code === "task_terminal"
  );

  // After the retention window elapses, the record is gone entirely.
  await new Promise((r) => setTimeout(r, 60));
  await assert.rejects(
    () => provider.cancelTask("task_done"),
    (err: unknown) => err instanceof HermesProviderError && err.code === "task_not_found"
  );
  assert.equal(events.filter((e) => e.type === "completed").length, 1, "cleanup must not re-emit or duplicate the terminal event");
});

test("MockHermesProvider default terminal retention keeps a just-completed task_terminal error available shortly after completion", async () => {
  // Regression guard: the default terminalRetentionMs must not be so
  // aggressive that it breaks the existing "cancel right after completion"
  // contract exercised elsewhere in this file.
  const provider = new MockHermesProvider({ minDelayMs: 1, maxDelayMs: 5 });
  const { events, listener, until } = collector();
  provider.onEvent(listener);

  await provider.createTask({ taskId: "task_immediate", hermesSessionId: "sess_1", instruction: "quick task" });
  await until((e) => e.some((ev) => ev.type === "completed"));
  assert.ok(events.some((e) => e.type === "completed"));

  await assert.rejects(
    () => provider.cancelTask("task_immediate"),
    (err: unknown) => err instanceof HermesProviderError && err.code === "task_terminal"
  );
});
