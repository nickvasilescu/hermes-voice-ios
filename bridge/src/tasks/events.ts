import type { Task } from "../types.js";

export type TaskEventType =
  | "task.created"
  | "task.progress"
  | "task.approval_required"
  | "task.completed"
  | "task.failed"
  | "task.canceled";

export interface TaskEvent {
  type: TaskEventType;
  task: Task;
}

export type TaskEventListener = (event: TaskEvent) => void;

/**
 * Per-hermesSessionId pub/sub, decoupled from HTTP/SSE so it can be unit
 * tested without spinning up a server. `http/routes/events.ts` is the only
 * place that turns this into `text/event-stream` bytes. [IMPLEMENTED]
 */
export class TaskEventBus {
  private readonly subscribers = new Map<string, Set<TaskEventListener>>();

  subscribe(hermesSessionId: string, listener: TaskEventListener): () => void {
    let set = this.subscribers.get(hermesSessionId);
    if (!set) {
      set = new Set();
      this.subscribers.set(hermesSessionId, set);
    }
    set.add(listener);
    return () => {
      set?.delete(listener);
      if (set && set.size === 0) this.subscribers.delete(hermesSessionId);
    };
  }

  publish(hermesSessionId: string, event: TaskEvent): void {
    const set = this.subscribers.get(hermesSessionId);
    if (!set) return;
    for (const listener of set) listener(event);
  }
}
