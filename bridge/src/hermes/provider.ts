import type { TaskError } from "../types.js";

/**
 * The seam a real Hermes deployment plugs into. See docs/PROTOCOL.md §5.
 * Implementations: `MockHermesProvider` (local) and `ApiServerHermesProvider`
 * (Hermes API Server `/v1/runs` + SSE).
 */
export interface CreateTaskInput {
  taskId: string;
  hermesSessionId: string;
  instruction: string;
  context?: unknown;
}

export type HermesProviderEvent =
  | { type: "status"; taskId: string; status: "running" }
  | { type: "progress"; taskId: string; percent?: number; message: string }
  | {
      type: "approval_required";
      taskId: string;
      approvalId: string;
      action: string;
      details?: Record<string, unknown>;
    }
  | { type: "completed"; taskId: string; result?: unknown; summary?: string }
  | { type: "failed"; taskId: string; error: TaskError }
  | { type: "canceled"; taskId: string };

export type HermesProviderListener = (event: HermesProviderEvent) => void;

export class HermesProviderError extends Error {
  code: string;

  constructor(code: string, message?: string) {
    super(message ?? code);
    this.name = "HermesProviderError";
    this.code = code;
  }
}

export interface HermesProvider {
  createTask(input: CreateTaskInput): Promise<void>;
  sendFollowup(taskId: string, message: string): Promise<void>;
  cancelTask(taskId: string, reason?: string): Promise<void>;
  resolveApproval(
    taskId: string,
    approvalId: string,
    decision: "approve" | "reject",
    note?: string
  ): Promise<void>;
  onEvent(listener: HermesProviderListener): () => void;
}
