import { randomUUID } from "node:crypto";
import { TTLMap } from "../util/ttlMap.js";
import type {
  PendingApproval,
  Task,
  TaskError,
  TaskHistoryKind,
  TaskProgress,
  TaskStatus,
} from "../types.js";

export interface CreateTaskParams {
  hermesSessionId: string;
  instruction: string;
  context?: unknown;
  clientRequestId?: string;
}

export interface TaskStoreOptions {
  /** How long a task lives since it was last created/mutated. */
  ttlMs?: number;
  /** Hard cap on the number of tasks held at once, oldest-touched evicted first. */
  maxEntries?: number;
  /** How long a clientRequestId dedupes a retried create. */
  idempotencyTtlMs?: number;
  idempotencyMaxEntries?: number;
  clock?: () => number;
}

const DEFAULT_TTL_MS = 24 * 60 * 60 * 1000;
const DEFAULT_MAX_ENTRIES = 5000;

/**
 * In-memory dev store [IMPLEMENTED]. Bounded and TTL-evicting (via
 * `TTLMap`) rather than an unbounded `Map`, so a long-running dev/demo
 * process can't be grown without limit by task creation traffic. Data
 * still does not survive a process restart; see docs/SECURITY.md and
 * docs/ARCHITECTURE.md for the tradeoffs and what a persistent store would
 * need.
 *
 * Note on `list()` ordering: a task's position is "most recently
 * created-or-touched", not strictly "most recently created" — every
 * mutation refreshes its TTL by re-inserting it, which also moves it to
 * the front of the newest-first listing. This reads naturally as a task
 * rail (recently-active tasks surface first) and is called out here so
 * it isn't mistaken for a bug.
 */
export class TaskStore {
  private readonly tasksById: TTLMap<string, Task>;
  private readonly idempotencyKeys: TTLMap<string, string>;

  constructor(options: TaskStoreOptions = {}) {
    this.tasksById = new TTLMap({
      ttlMs: options.ttlMs ?? DEFAULT_TTL_MS,
      maxEntries: options.maxEntries ?? DEFAULT_MAX_ENTRIES,
      clock: options.clock,
    });
    this.idempotencyKeys = new TTLMap({
      ttlMs: options.idempotencyTtlMs ?? DEFAULT_TTL_MS,
      maxEntries: options.idempotencyMaxEntries ?? DEFAULT_MAX_ENTRIES,
      clock: options.clock,
    });
  }

  /**
   * `created: false` means an unexpired idempotency record already pointed
   * at an existing task — this is the single source of truth for that
   * distinction. `TaskService` must not keep its own parallel bookkeeping
   * of "have I seen this clientRequestId before": doing so let a task
   * created after the store's own idempotency entry had TTL-expired (a
   * *new* task, correctly reported here as `created: true`) get silently
   * mistaken for a replay by a longer-lived, separately-tracked set, which
   * left that new task stuck in `queued` forever with no provider dispatch
   * and no SSE event. Whatever this method reports is authoritative.
   */
  create(params: CreateTaskParams): { task: Task; created: boolean } {
    if (params.clientRequestId) {
      const idempotencyKey = `${params.hermesSessionId}:${params.clientRequestId}`;
      const existingId = this.idempotencyKeys.get(idempotencyKey);
      if (existingId) {
        const existing = this.tasksById.get(existingId);
        if (existing) return { task: existing, created: false };
        // The idempotency record outlived the task itself (different TTLs,
        // or the task was independently evicted) — fall through and treat
        // this as a fresh creation, same as if no record existed.
      }
      const task = this.insert(params);
      this.idempotencyKeys.set(idempotencyKey, task.id);
      return { task, created: true };
    }
    return { task: this.insert(params), created: true };
  }

  private insert(params: CreateTaskParams): Task {
    const now = new Date().toISOString();
    const task: Task = {
      id: `task_${randomUUID()}`,
      hermesSessionId: params.hermesSessionId,
      status: "queued",
      instruction: params.instruction,
      createdAt: now,
      updatedAt: now,
      history: [{ at: now, kind: "created", message: "Task created." }],
    };
    this.tasksById.set(task.id, task);
    return task;
  }

  get(hermesSessionId: string, taskId: string): Task | undefined {
    const task = this.tasksById.peek(taskId);
    if (!task || task.hermesSessionId !== hermesSessionId) return undefined;
    return task;
  }

  /** Looks up a task by id only, used to route async provider events. */
  findByTaskId(taskId: string): Task | undefined {
    return this.tasksById.peek(taskId);
  }

  list(hermesSessionId: string, status?: TaskStatus): Task[] {
    // TTLMap.values() yields in insertion order; reverse for newest-first
    // without relying on createdAt string comparisons, which can tie
    // within the same millisecond under fast test execution.
    return [...this.tasksById.values()]
      .reverse()
      .filter((t) => t.hermesSessionId === hermesSessionId)
      .filter((t) => (status ? t.status === status : true));
  }

  appendFollowup(hermesSessionId: string, taskId: string, message: string): Task | undefined {
    return this.mutate(hermesSessionId, taskId, (task) => {
      this.pushHistory(task, "followup", `Follow-up: ${message}`);
    });
  }

  applyStatus(hermesSessionId: string, taskId: string, status: TaskStatus): Task | undefined {
    return this.mutate(hermesSessionId, taskId, (task) => {
      task.status = status;
    });
  }

  applyProgress(hermesSessionId: string, taskId: string, progress: TaskProgress): Task | undefined {
    return this.mutate(hermesSessionId, taskId, (task) => {
      task.progress = progress;
      task.status = task.status === "queued" ? "running" : task.status;
      this.pushHistory(task, "progress", progress.message ?? "Progress update.");
    });
  }

  setPendingApproval(
    hermesSessionId: string,
    taskId: string,
    approval: PendingApproval
  ): Task | undefined {
    return this.mutate(hermesSessionId, taskId, (task) => {
      task.status = "waiting_approval";
      task.pendingApproval = approval;
      this.pushHistory(task, "approval_requested", `Approval requested: ${approval.action}`);
    });
  }

  clearPendingApproval(hermesSessionId: string, taskId: string): Task | undefined {
    return this.mutate(hermesSessionId, taskId, (task) => {
      delete task.pendingApproval;
      this.pushHistory(task, "approval_resolved", "Approval resolved.");
    });
  }

  complete(
    hermesSessionId: string,
    taskId: string,
    outcome: { result?: unknown; summary?: string }
  ): Task | undefined {
    return this.mutate(hermesSessionId, taskId, (task) => {
      task.status = "completed";
      task.result = outcome.result;
      task.summary = outcome.summary;
      delete task.pendingApproval;
      this.pushHistory(task, "terminal", outcome.summary ?? "Task completed.");
    });
  }

  fail(hermesSessionId: string, taskId: string, error: TaskError): Task | undefined {
    return this.mutate(hermesSessionId, taskId, (task) => {
      task.status = "failed";
      task.error = error;
      delete task.pendingApproval;
      this.pushHistory(task, "terminal", `Task failed: ${error.message}`);
    });
  }

  cancel(hermesSessionId: string, taskId: string, reason?: string): Task | undefined {
    return this.mutate(hermesSessionId, taskId, (task) => {
      task.status = "canceled";
      delete task.pendingApproval;
      this.pushHistory(task, "terminal", reason ? `Canceled: ${reason}` : "Canceled.");
    });
  }

  /** Looks up by taskId alone (provider events only know the taskId), but
   *  still enforces the session actually owns it before mutating. */
  private mutate(hermesSessionId: string, taskId: string, fn: (task: Task) => void): Task | undefined {
    const task = this.get(hermesSessionId, taskId);
    if (!task) return undefined;
    fn(task);
    task.updatedAt = new Date().toISOString();
    this.tasksById.set(taskId, task); // refresh TTL + re-bound eviction order
    return task;
  }

  private pushHistory(task: Task, kind: TaskHistoryKind, message: string): void {
    task.history.push({ at: new Date().toISOString(), kind, message });
  }
}
