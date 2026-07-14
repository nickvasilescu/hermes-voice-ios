import { test } from "node:test";
import assert from "node:assert/strict";
import { TaskStore } from "../src/tasks/store.js";
import { TaskEventBus } from "../src/tasks/events.js";
import { MockHermesProvider } from "../src/hermes/mockProvider.js";
import { HermesProviderError, type CreateTaskInput, type HermesProvider, type HermesProviderListener } from "../src/hermes/provider.js";
import { TaskService, TaskServiceError } from "../src/tasks/service.js";
import type { TaskEvent } from "../src/tasks/events.js";

function makeService(delays: { minDelayMs: number; maxDelayMs: number } = { minDelayMs: 1, maxDelayMs: 5 }) {
  const store = new TaskStore();
  const eventBus = new TaskEventBus();
  const provider = new MockHermesProvider(delays);
  const service = new TaskService(store, provider, eventBus);
  return { store, eventBus, provider, service };
}

function collectSSE(eventBus: TaskEventBus, hermesSessionId: string) {
  const events: TaskEvent[] = [];
  eventBus.subscribe(hermesSessionId, (e) => events.push(e));
  return events;
}

function waitUntil(predicate: () => boolean, timeoutMs = 2000): Promise<void> {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    const tick = () => {
      if (predicate()) return resolve();
      if (Date.now() - start > timeoutMs) return reject(new Error("timed out"));
      setTimeout(tick, 5);
    };
    tick();
  });
}

/** A provider whose calls can be made to fail on demand, for regression-testing error handling. */
class FlakyProvider implements HermesProvider {
  createTaskShouldFail = false;
  sendFollowupShouldFail = false;
  private listeners = new Set<HermesProviderListener>();

  async createTask(_input: CreateTaskInput): Promise<void> {
    if (this.createTaskShouldFail) throw new Error("upstream Hermes is unreachable");
  }

  async sendFollowup(_taskId: string, _message: string): Promise<void> {
    if (this.sendFollowupShouldFail) throw new HermesProviderError("task_terminal", "task just completed");
  }

  async cancelTask(): Promise<void> {}

  async resolveApproval(): Promise<void> {}

  onEvent(listener: HermesProviderListener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }
}

test("TaskService.createTask publishes task.created and runs a task to completion via SSE", async () => {
  const { service, eventBus } = makeService();
  const events = collectSSE(eventBus, "sess_1");

  const { task, created } = service.createTask({ hermesSessionId: "sess_1", instruction: "do a thing" });
  assert.equal(created, true);
  assert.equal(task.status, "queued");
  assert.equal(events.at(-1)?.type, "task.created");

  await waitUntil(() => events.some((e) => e.type === "task.completed"));
  const finalTask = service.getTask("sess_1", task.id);
  assert.equal(finalTask.status, "completed");
});

test("TaskService.createTask is idempotent on clientRequestId: created is false on replay and the provider is called once", async () => {
  const { service, eventBus } = makeService();
  const events = collectSSE(eventBus, "sess_1");

  const a = service.createTask({ hermesSessionId: "sess_1", instruction: "x", clientRequestId: "req-1" });
  const b = service.createTask({ hermesSessionId: "sess_1", instruction: "x", clientRequestId: "req-1" });
  assert.equal(a.task.id, b.task.id);
  assert.equal(a.created, true);
  assert.equal(b.created, false);

  await waitUntil(() => events.filter((e) => e.type === "task.created").length >= 1);
  await new Promise((r) => setTimeout(r, 30));
  assert.equal(events.filter((e) => e.type === "task.created").length, 1);
});

test("TaskService.createTask transitions the task to failed and publishes it when the provider create call throws", async () => {
  const store = new TaskStore();
  const eventBus = new TaskEventBus();
  const provider = new FlakyProvider();
  provider.createTaskShouldFail = true;
  const service = new TaskService(store, provider, eventBus);
  const events = collectSSE(eventBus, "sess_1");

  const { task } = service.createTask({ hermesSessionId: "sess_1", instruction: "do a thing" });

  await waitUntil(() => events.some((e) => e.type === "task.failed"));
  const finalTask = service.getTask("sess_1", task.id);
  assert.equal(finalTask.status, "failed");
  assert.match(finalTask.error?.message ?? "", /unreachable/);
});

test("TaskService.getTask throws task_not_found (404) for unknown or cross-session ids", () => {
  const { service } = makeService();
  const { task } = service.createTask({ hermesSessionId: "sess_1", instruction: "x" });

  assert.throws(
    () => service.getTask("sess_1", "task_nope"),
    (err: unknown) => err instanceof TaskServiceError && err.code === "task_not_found" && err.status === 404
  );
  assert.throws(
    () => service.getTask("sess_other", task.id),
    (err: unknown) => err instanceof TaskServiceError && err.status === 404
  );
});

test("TaskService.followup appends history and rejects on a terminal task with 409", async () => {
  const { service } = makeService();
  const { task } = service.createTask({ hermesSessionId: "sess_1", instruction: "quick task" });

  const updated = await service.followup("sess_1", task.id, "extra info");
  assert.equal(updated.history.some((h) => h.kind === "followup"), true);

  await waitUntil(() => service.getTask("sess_1", task.id).status === "completed");

  await assert.rejects(
    () => service.followup("sess_1", task.id, "too late"),
    (err: unknown) => err instanceof TaskServiceError && err.code === "task_terminal" && err.status === 409
  );
});

test("TaskService.followup does not persist a followup the provider rejects", async () => {
  const store = new TaskStore();
  const eventBus = new TaskEventBus();
  const provider = new FlakyProvider();
  const service = new TaskService(store, provider, eventBus);

  const { task } = service.createTask({ hermesSessionId: "sess_1", instruction: "x" });
  provider.sendFollowupShouldFail = true;

  await assert.rejects(
    () => service.followup("sess_1", task.id, "this should not stick"),
    (err: unknown) => err instanceof TaskServiceError && err.code === "task_terminal"
  );

  const current = service.getTask("sess_1", task.id);
  assert.equal(
    current.history.some((h) => h.kind === "followup"),
    false,
    "a rejected followup must not appear in history as if it were accepted"
  );
});

test("TaskService.cancel transitions the task to canceled via the provider event pipeline", async () => {
  const { service, eventBus } = makeService({ minDelayMs: 50, maxDelayMs: 60 });
  const events = collectSSE(eventBus, "sess_1");
  const { task } = service.createTask({ hermesSessionId: "sess_1", instruction: "long task" });

  const canceled = await service.cancel("sess_1", task.id, "changed my mind");
  assert.equal(canceled.status, "canceled");
  assert.ok(events.some((e) => e.type === "task.canceled"));

  await new Promise((r) => setTimeout(r, 80));
  assert.equal(service.getTask("sess_1", task.id).status, "canceled");
});

test("TaskService.cancel on an already-terminal task throws 409", async () => {
  const { service } = makeService();
  const { task } = service.createTask({ hermesSessionId: "sess_1", instruction: "quick task" });
  await waitUntil(() => service.getTask("sess_1", task.id).status === "completed");

  await assert.rejects(
    () => service.cancel("sess_1", task.id),
    (err: unknown) => err instanceof TaskServiceError && err.code === "task_terminal" && err.status === 409
  );
});

test("TaskService.approve resolves a pending approval and the task later completes", async () => {
  const { service, eventBus } = makeService();
  const events = collectSSE(eventBus, "sess_1");
  const { task } = service.createTask({ hermesSessionId: "sess_1", instruction: "please approve this" });

  await waitUntil(() => events.some((e) => e.type === "task.approval_required"));
  const approvalEvent = events.find((e) => e.type === "task.approval_required");
  const approvalId = approvalEvent?.task.pendingApproval?.approvalId;
  assert.ok(approvalId);

  await service.approve("sess_1", task.id, approvalId as string, "approve");
  await waitUntil(() => service.getTask("sess_1", task.id).status === "completed");
  assert.equal(service.getTask("sess_1", task.id).pendingApproval, undefined);
});

test("TaskService.approve with a mismatched approvalId throws 409", async () => {
  const { service, eventBus } = makeService();
  const events = collectSSE(eventBus, "sess_1");
  const { task } = service.createTask({ hermesSessionId: "sess_1", instruction: "please approve this" });
  await waitUntil(() => events.some((e) => e.type === "task.approval_required"));

  await assert.rejects(
    () => service.approve("sess_1", task.id, "appr_wrong", "approve"),
    (err: unknown) => err instanceof TaskServiceError && err.code === "no_matching_approval" && err.status === 409
  );
});

test("TaskService.listTasks scopes by session and supports status filter", async () => {
  const { service } = makeService();
  service.createTask({ hermesSessionId: "sess_1", instruction: "a" });
  service.createTask({ hermesSessionId: "sess_1", instruction: "b" });
  service.createTask({ hermesSessionId: "sess_2", instruction: "c" });

  assert.equal(service.listTasks("sess_1").length, 2);
  assert.equal(service.listTasks("sess_1", "queued").length, 2);
  assert.equal(service.listTasks("sess_2").length, 1);
});
