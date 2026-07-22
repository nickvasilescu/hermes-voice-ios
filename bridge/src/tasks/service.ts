import { HermesProviderError, type HermesProvider, type HermesProviderEvent } from "../hermes/provider.js";
import { isTerminal, type Task, type TaskStatus } from "../types.js";
import { TaskEventBus, type TaskEventType } from "./events.js";
import { TaskStore } from "./store.js";

export class TaskServiceError extends Error {
  code: string;
  status: number;

  constructor(code: string, status: number, message?: string) {
    super(message ?? code);
    this.name = "TaskServiceError";
    this.code = code;
    this.status = status;
  }
}

export interface CreateTaskRequest {
  hermesSessionId: string;
  instruction: string;
  context?: unknown;
  clientRequestId?: string;
}

const PROVIDER_ERROR_STATUS: Record<string, number> = {
  task_not_found: 404,
  task_terminal: 409,
  no_matching_approval: 409,
};

/**
 * Orchestrates TaskStore + HermesProvider + TaskEventBus. This is the one
 * place that knows how the five tools map onto store mutations and SSE
 * events. [IMPLEMENTED]
 */
export class TaskService {
  constructor(
    private readonly store: TaskStore,
    private readonly provider: HermesProvider,
    private readonly eventBus: TaskEventBus,
    private readonly onProviderError: (err: unknown) => void = () => {}
  ) {
    this.provider.onEvent((event) => this.handleProviderEvent(event));
  }

  /**
   * `created: false` means this was an idempotent replay of an
   * already-seen `clientRequestId` — callers should respond 200, not 201
   * (see docs/PROTOCOL.md §4). This flag comes directly from
   * `TaskStore.create` — see that method's doc comment for why this
   * service must not keep any parallel "have I seen this before"
   * bookkeeping of its own.
   */
  createTask(request: CreateTaskRequest): { task: Task; created: boolean } {
    const { task, created } = this.store.create(request);

    if (created) {
      this.eventBus.publish(request.hermesSessionId, { type: "task.created", task });
      this.provider
        .createTask({
          taskId: task.id,
          hermesSessionId: request.hermesSessionId,
          hermesThreadId: task.hermesThreadId,
          instruction: request.instruction,
          context: request.context,
        })
        .catch((err) => {
          this.onProviderError(err);
          this.failTaskFromProviderError(request.hermesSessionId, task.id, err);
        });
    }

    return { task, created };
  }

  getTask(hermesSessionId: string, taskId: string): Task {
    const task = this.store.get(hermesSessionId, taskId);
    if (!task) throw new TaskServiceError("task_not_found", 404);
    return task;
  }

  listTasks(hermesSessionId: string, status?: TaskStatus): Task[] {
    return this.store.list(hermesSessionId, status);
  }

  async followup(hermesSessionId: string, taskId: string, message: string): Promise<Task> {
    const task = this.getTask(hermesSessionId, taskId);
    if (isTerminal(task.status)) throw new TaskServiceError("task_terminal", 409);

    // Call the provider FIRST: a rejected followup (e.g. the provider races
    // to a terminal state) must not be recorded in history as if it were
    // accepted. Only persist once the provider has actually acknowledged it.
    await this.callProvider(() => this.provider.sendFollowup(taskId, message));

    const updated = this.store.appendFollowup(hermesSessionId, taskId, message);
    if (!updated) throw new TaskServiceError("task_not_found", 404);
    return updated;
  }

  async cancel(hermesSessionId: string, taskId: string, reason?: string): Promise<Task> {
    const task = this.getTask(hermesSessionId, taskId);
    if (isTerminal(task.status)) throw new TaskServiceError("task_terminal", 409);

    await this.callProvider(() => this.provider.cancelTask(taskId, reason));
    return this.getTask(hermesSessionId, taskId);
  }

  async approve(
    hermesSessionId: string,
    taskId: string,
    approvalId: string,
    decision: "approve" | "reject",
    note?: string
  ): Promise<Task> {
    const task = this.getTask(hermesSessionId, taskId);
    if (isTerminal(task.status)) throw new TaskServiceError("task_terminal", 409);
    if (task.status !== "waiting_approval" || task.pendingApproval?.approvalId !== approvalId) {
      throw new TaskServiceError("no_matching_approval", 409);
    }

    await this.callProvider(() => this.provider.resolveApproval(taskId, approvalId, decision, note));
    // Provider accepted the decision — clear the gate immediately so the
    // rail / Realtime model don't keep prompting for the same approval
    // while Hermes resumes the run.
    const cleared = this.store.clearPendingApproval(hermesSessionId, taskId);
    if (cleared) this.publish(hermesSessionId, "task.progress", cleared);
    return this.getTask(hermesSessionId, taskId);
  }

  private async callProvider(fn: () => Promise<void>): Promise<void> {
    try {
      await fn();
    } catch (err) {
      if (err instanceof HermesProviderError) {
        const status = PROVIDER_ERROR_STATUS[err.code] ?? 502;
        throw new TaskServiceError(err.code, status, err.message);
      }
      throw new TaskServiceError("provider_error", 502, err instanceof Error ? err.message : String(err));
    }
  }

  /**
   * A task whose `provider.createTask(...)` call itself throws (as opposed
   * to failing asynchronously via a `"failed"` provider event) would
   * otherwise sit stuck in `"queued"` forever with no explanation. Move it
   * to `failed` and publish it exactly like any other terminal transition.
   */
  private failTaskFromProviderError(hermesSessionId: string, taskId: string, err: unknown): void {
    const current = this.store.get(hermesSessionId, taskId);
    if (!current || isTerminal(current.status)) return;
    const message = err instanceof Error ? err.message : String(err);
    const code = err instanceof HermesProviderError ? err.code : "provider_error";
    const updated = this.store.fail(hermesSessionId, taskId, { message, code });
    if (updated) this.publish(hermesSessionId, "task.failed", updated);
  }

  private handleProviderEvent(event: HermesProviderEvent): void {
    const known = this.store.findByTaskId(event.taskId);
    if (!known) return;
    const hermesSessionId = known.hermesSessionId;

    switch (event.type) {
      case "status": {
        const updated = this.store.applyStatus(hermesSessionId, event.taskId, event.status);
        if (updated) this.publish(hermesSessionId, "task.progress", updated);
        return;
      }
      case "progress": {
        const updated = this.store.applyProgress(hermesSessionId, event.taskId, {
          percent: event.percent,
          message: event.message,
        });
        if (updated) this.publish(hermesSessionId, "task.progress", updated);
        return;
      }
      case "approval_required": {
        const updated = this.store.setPendingApproval(hermesSessionId, event.taskId, {
          approvalId: event.approvalId,
          action: event.action,
          details: event.details,
          requestedAt: new Date().toISOString(),
        });
        if (updated) this.publish(hermesSessionId, "task.approval_required", updated);
        return;
      }
      case "completed": {
        const updated = this.store.complete(hermesSessionId, event.taskId, {
          result: event.result,
          summary: event.summary,
        });
        if (updated) this.publish(hermesSessionId, "task.completed", updated);
        return;
      }
      case "failed": {
        const updated = this.store.fail(hermesSessionId, event.taskId, event.error);
        if (updated) this.publish(hermesSessionId, "task.failed", updated);
        return;
      }
      case "canceled": {
        const updated = this.store.cancel(hermesSessionId, event.taskId);
        if (updated) this.publish(hermesSessionId, "task.canceled", updated);
        return;
      }
    }
  }

  private publish(hermesSessionId: string, type: TaskEventType, task: Task): void {
    this.eventBus.publish(hermesSessionId, { type, task });
  }
}
