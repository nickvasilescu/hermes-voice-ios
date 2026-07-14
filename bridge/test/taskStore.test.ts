import { test } from "node:test";
import assert from "node:assert/strict";
import { TaskStore } from "../src/tasks/store.js";

test("TaskStore.create assigns an id, defaults, and history entry, and reports created: true", () => {
  const store = new TaskStore();
  const { task, created } = store.create({
    hermesSessionId: "sess_1",
    instruction: "do a thing",
  });

  assert.equal(created, true);
  assert.match(task.id, /^task_/);
  assert.equal(task.status, "queued");
  assert.equal(task.hermesSessionId, "sess_1");
  assert.equal(task.history.length, 1);
  assert.equal(task.history[0]?.kind, "created");
});

test("TaskStore.get scopes lookups by hermesSessionId", () => {
  const store = new TaskStore();
  const { task } = store.create({ hermesSessionId: "sess_1", instruction: "x" });

  assert.deepEqual(store.get("sess_1", task.id), task);
  assert.equal(store.get("sess_other", task.id), undefined);
  assert.equal(store.get("sess_1", "task_nope"), undefined);
});

test("TaskStore.list returns tasks for a session, newest first, optionally filtered by status", () => {
  const store = new TaskStore();
  const { task: a } = store.create({ hermesSessionId: "sess_1", instruction: "a" });
  const { task: b } = store.create({ hermesSessionId: "sess_1", instruction: "b" });
  store.create({ hermesSessionId: "sess_2", instruction: "other session" });

  const listed = store.list("sess_1");
  assert.deepEqual(
    listed.map((t) => t.id),
    [b.id, a.id]
  );

  store.applyStatus("sess_1", a.id, "completed");
  const onlyCompleted = store.list("sess_1", "completed");
  assert.deepEqual(
    onlyCompleted.map((t) => t.id),
    [a.id]
  );
});

test("TaskStore idempotency: same clientRequestId returns the same task and created: false on replay", () => {
  const store = new TaskStore();
  const first = store.create({
    hermesSessionId: "sess_1",
    instruction: "do a thing",
    clientRequestId: "req-1",
  });
  const second = store.create({
    hermesSessionId: "sess_1",
    instruction: "do a thing again but ignored",
    clientRequestId: "req-1",
  });

  assert.equal(first.created, true);
  assert.equal(second.created, false);
  assert.equal(first.task.id, second.task.id);
  assert.equal(store.list("sess_1").length, 1);
});

test("TaskStore idempotency is scoped per hermesSessionId", () => {
  const store = new TaskStore();
  const { task: a } = store.create({ hermesSessionId: "sess_1", instruction: "a", clientRequestId: "req-1" });
  const { task: b, created } = store.create({ hermesSessionId: "sess_2", instruction: "b", clientRequestId: "req-1" });
  assert.notEqual(a.id, b.id);
  assert.equal(created, true);
});

test("TaskStore idempotency record expiring independently of the task record still reports created: true and mints a new id", () => {
  // Regression test: the idempotency TTL and the task TTL are separate
  // TTLMaps. If the idempotency record expires first, a replay must be
  // treated as a fresh creation (created: true, a brand-new task id) —
  // never silently dropped.
  let now = 0;
  const store = new TaskStore({
    ttlMs: 10_000, // tasks live long
    idempotencyTtlMs: 100, // idempotency window is short
    clock: () => now,
  });

  const first = store.create({ hermesSessionId: "sess_1", instruction: "a", clientRequestId: "req-1" });
  assert.equal(first.created, true);

  now = 200; // idempotency record has expired; task record has not
  const second = store.create({ hermesSessionId: "sess_1", instruction: "a", clientRequestId: "req-1" });

  assert.equal(second.created, true, "a replay after the idempotency window closes must mint a new task, not be silently swallowed");
  assert.notEqual(second.task.id, first.task.id);
  assert.equal(store.list("sess_1").length, 2, "both the original and the post-expiry replay must exist as real tasks");
});

test("TaskStore.appendFollowup records history without changing terminal state", () => {
  const store = new TaskStore();
  const { task } = store.create({ hermesSessionId: "sess_1", instruction: "a" });
  const updated = store.appendFollowup("sess_1", task.id, "more info");
  assert.equal(updated?.history.length, 2);
  assert.equal(updated?.history[1]?.kind, "followup");
  assert.equal(updated?.status, "queued");
});

test("TaskStore.applyStatus moves through the lifecycle and stamps updatedAt", async () => {
  const store = new TaskStore();
  const { task } = store.create({ hermesSessionId: "sess_1", instruction: "a" });
  const originalUpdatedAt = task.updatedAt;
  await new Promise((r) => setTimeout(r, 5));
  const running = store.applyStatus("sess_1", task.id, "running");
  assert.equal(running?.status, "running");
  assert.notEqual(running?.updatedAt, originalUpdatedAt);
});

test("TaskStore.applyProgress merges progress and appends history", () => {
  const store = new TaskStore();
  const { task } = store.create({ hermesSessionId: "sess_1", instruction: "a" });
  const updated = store.applyProgress("sess_1", task.id, { percent: 40, message: "halfway" });
  assert.deepEqual(updated?.progress, { percent: 40, message: "halfway" });
  assert.equal(updated?.history.at(-1)?.kind, "progress");
});

test("TaskStore.setPendingApproval sets waiting_approval and clearing it restores flow", () => {
  const store = new TaskStore();
  const { task } = store.create({ hermesSessionId: "sess_1", instruction: "a" });
  const waiting = store.setPendingApproval("sess_1", task.id, {
    approvalId: "appr_1",
    action: "confirm_action",
    requestedAt: new Date().toISOString(),
  });
  assert.equal(waiting?.status, "waiting_approval");
  assert.equal(waiting?.pendingApproval?.approvalId, "appr_1");

  const cleared = store.clearPendingApproval("sess_1", task.id);
  assert.equal(cleared?.pendingApproval, undefined);
});

test("TaskStore.complete/fail/cancel set terminal state and result/error", () => {
  const store = new TaskStore();
  const { task: t1 } = store.create({ hermesSessionId: "sess_1", instruction: "a" });
  const completed = store.complete("sess_1", t1.id, { result: { ok: true }, summary: "done" });
  assert.equal(completed?.status, "completed");
  assert.deepEqual(completed?.result, { ok: true });

  const { task: t2 } = store.create({ hermesSessionId: "sess_1", instruction: "b" });
  const failed = store.fail("sess_1", t2.id, { message: "boom", code: "x" });
  assert.equal(failed?.status, "failed");
  assert.equal(failed?.error?.code, "x");

  const { task: t3 } = store.create({ hermesSessionId: "sess_1", instruction: "c" });
  const canceled = store.cancel("sess_1", t3.id, "nvm");
  assert.equal(canceled?.status, "canceled");
});

test("TaskStore.findByTaskId is used internally to route provider events without needing hermesSessionId", () => {
  const store = new TaskStore();
  const { task } = store.create({ hermesSessionId: "sess_1", instruction: "a" });
  const found = store.findByTaskId(task.id);
  assert.equal(found?.hermesSessionId, "sess_1");
  assert.equal(store.findByTaskId("nope"), undefined);
});
