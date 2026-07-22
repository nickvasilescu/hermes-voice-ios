import { test } from "node:test";
import assert from "node:assert/strict";
import { TaskEventBus } from "../src/tasks/events.js";
import type { Task } from "../src/types.js";

function fakeTask(overrides: Partial<Task> = {}): Task {
  const now = new Date().toISOString();
  return {
    id: "task_1",
    hermesSessionId: "sess_1",
    hermesThreadId: "ht_1",
    status: "queued",
    instruction: "x",
    createdAt: now,
    updatedAt: now,
    history: [],
    ...overrides,
  };
}

test("TaskEventBus delivers published events only to subscribers of that session", () => {
  const bus = new TaskEventBus();
  const receivedA: string[] = [];
  const receivedB: string[] = [];
  bus.subscribe("sess_1", (e) => receivedA.push(e.type));
  bus.subscribe("sess_2", (e) => receivedB.push(e.type));

  bus.publish("sess_1", { type: "task.created", task: fakeTask() });

  assert.deepEqual(receivedA, ["task.created"]);
  assert.deepEqual(receivedB, []);
});

test("TaskEventBus supports multiple subscribers on the same session", () => {
  const bus = new TaskEventBus();
  let count = 0;
  bus.subscribe("sess_1", () => count++);
  bus.subscribe("sess_1", () => count++);

  bus.publish("sess_1", { type: "task.progress", task: fakeTask() });
  assert.equal(count, 2);
});

test("TaskEventBus unsubscribe stops delivery", () => {
  const bus = new TaskEventBus();
  const received: string[] = [];
  const unsubscribe = bus.subscribe("sess_1", (e) => received.push(e.type));
  unsubscribe();

  bus.publish("sess_1", { type: "task.completed", task: fakeTask() });
  assert.deepEqual(received, []);
});

test("TaskEventBus publish with no subscribers is a no-op", () => {
  const bus = new TaskEventBus();
  assert.doesNotThrow(() => bus.publish("sess_none", { type: "task.created", task: fakeTask() }));
});
