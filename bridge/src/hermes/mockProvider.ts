import { randomUUID } from "node:crypto";
import { TTLMap } from "../util/ttlMap.js";
import {
  HermesProviderError,
  type CreateTaskInput,
  type HermesProvider,
  type HermesProviderEvent,
  type HermesProviderListener,
} from "./provider.js";

interface InternalTask {
  instruction: string;
  terminal: boolean;
  pendingApprovalId?: string;
  timers: NodeJS.Timeout[];
}

export interface MockHermesProviderOptions {
  /** Lower bound, in ms, for the synthetic delay between lifecycle steps. */
  minDelayMs?: number;
  /** Upper bound, in ms, for the synthetic delay between lifecycle steps. */
  maxDelayMs?: number;
  /** Hard cap on internally-tracked tasks at once, oldest-touched evicted first. */
  maxEntries?: number;
  /** How long an internal task record lives since it was last touched. */
  ttlMs?: number;
  /**
   * How long a *terminal* task record is kept around before this provider
   * proactively deletes it — shorter than `ttlMs` on purpose. A busy dev
   * process handling many short-lived tasks would otherwise accumulate
   * finished-forever entries for the full TTL; this reclaims that memory
   * promptly while still giving a near-simultaneous late call (a
   * follow-up/cancel/approval racing the completion) a clear
   * `task_terminal` rather than a confusing `task_not_found`.
   */
  terminalRetentionMs?: number;
  clock?: () => number;
}

const DEFAULT_MAX_ENTRIES = 5000;
const DEFAULT_TTL_MS = 24 * 60 * 60 * 1000;
const DEFAULT_TERMINAL_RETENTION_MS = 5 * 60 * 1000;

/**
 * A deterministic-enough, fully local stand-in for a real Hermes deployment.
 * [MOCKED] — see docs/PROTOCOL.md §5. Used as the default provider in dev
 * and in tests. Any instruction containing the word "approve" (case
 * insensitive) synthesizes an approval gate so that flow is exercisable
 * without a real Hermes backend.
 *
 * Internal task bookkeeping is bounded via `TTLMap` (same mechanism as
 * `TaskStore`) rather than a plain `Map`, and terminal tasks are
 * proactively removed after `terminalRetentionMs` — a long-running dev
 * process pushing many tasks through this provider should not accumulate
 * unbounded (or even just slowly-expiring) memory for tasks that finished
 * hours ago.
 */
export class MockHermesProvider implements HermesProvider {
  private readonly tasks: TTLMap<string, InternalTask>;
  private readonly listeners = new Set<HermesProviderListener>();
  private readonly minDelayMs: number;
  private readonly maxDelayMs: number;
  private readonly terminalRetentionMs: number;

  constructor(options: MockHermesProviderOptions = {}) {
    this.minDelayMs = options.minDelayMs ?? 30;
    this.maxDelayMs = options.maxDelayMs ?? 90;
    this.terminalRetentionMs = options.terminalRetentionMs ?? DEFAULT_TERMINAL_RETENTION_MS;
    this.tasks = new TTLMap({
      maxEntries: options.maxEntries ?? DEFAULT_MAX_ENTRIES,
      ttlMs: options.ttlMs ?? DEFAULT_TTL_MS,
      clock: options.clock,
    });
  }

  onEvent(listener: HermesProviderListener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  async createTask(input: CreateTaskInput): Promise<void> {
    const internal: InternalTask = {
      instruction: input.instruction,
      terminal: false,
      timers: [],
    };
    this.tasks.set(input.taskId, internal);

    this.schedule(internal, () => {
      this.emit({ type: "status", taskId: input.taskId, status: "running" });

      this.schedule(internal, () => {
        this.emit({
          type: "progress",
          taskId: input.taskId,
          percent: 50,
          message: "Working on it...",
        });

        this.schedule(internal, () => {
          if (/\bapprove\b/i.test(input.instruction)) {
            const approvalId = `appr_${randomUUID()}`;
            internal.pendingApprovalId = approvalId;
            this.emit({
              type: "approval_required",
              taskId: input.taskId,
              approvalId,
              action: "confirm_action",
              details: { instruction: input.instruction },
            });
          } else {
            this.markTerminal(input.taskId, internal);
            this.emit({
              type: "completed",
              taskId: input.taskId,
              result: { echoedInstruction: input.instruction },
              summary: "Done.",
            });
          }
        });
      });
    });
  }

  async sendFollowup(taskId: string, message: string): Promise<void> {
    const internal = this.requireTask(taskId);
    if (internal.terminal) throw new HermesProviderError("task_terminal");

    this.schedule(internal, () => {
      this.emit({
        type: "progress",
        taskId,
        message: `Received follow-up: ${message}`,
      });
    });
  }

  async cancelTask(taskId: string, _reason?: string): Promise<void> {
    const internal = this.requireTask(taskId);
    if (internal.terminal) throw new HermesProviderError("task_terminal");

    for (const timer of internal.timers) clearTimeout(timer);
    internal.timers = [];
    this.markTerminal(taskId, internal);
    this.emit({ type: "canceled", taskId });
  }

  async resolveApproval(
    taskId: string,
    approvalId: string,
    decision: "approve" | "reject",
    _note?: string
  ): Promise<void> {
    const internal = this.requireTask(taskId);
    if (internal.terminal) throw new HermesProviderError("task_terminal");
    if (internal.pendingApprovalId !== approvalId) {
      throw new HermesProviderError("no_matching_approval");
    }
    internal.pendingApprovalId = undefined;

    this.schedule(internal, () => {
      if (decision === "approve") {
        this.markTerminal(taskId, internal);
        this.emit({
          type: "completed",
          taskId,
          result: { approved: true },
          summary: "Approved and completed.",
        });
      } else {
        this.markTerminal(taskId, internal);
        this.emit({
          type: "failed",
          taskId,
          error: { message: "Rejected by user.", code: "approval_rejected" },
        });
      }
    });
  }

  private requireTask(taskId: string): InternalTask {
    const internal = this.tasks.get(taskId);
    if (!internal) throw new HermesProviderError("task_not_found");
    return internal;
  }

  /** Marks a task terminal and schedules its prompt (but not instant) removal. */
  private markTerminal(taskId: string, internal: InternalTask): void {
    internal.terminal = true;
    const cleanupTimer = setTimeout(() => {
      this.tasks.delete(taskId);
    }, this.terminalRetentionMs);
    cleanupTimer.unref?.();
  }

  private schedule(internal: InternalTask, fn: () => void): void {
    const delay =
      this.minDelayMs + Math.floor(Math.random() * Math.max(1, this.maxDelayMs - this.minDelayMs));
    const timer = setTimeout(() => {
      internal.timers = internal.timers.filter((t) => t !== timer);
      if (internal.terminal) return;
      fn();
    }, delay);
    internal.timers.push(timer);
  }

  private emit(event: HermesProviderEvent): void {
    for (const listener of this.listeners) listener(event);
  }
}
