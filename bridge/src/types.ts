export type TaskStatus =
  | "queued"
  | "running"
  | "waiting_approval"
  | "completed"
  | "failed"
  | "canceled";

export interface TaskProgress {
  percent?: number;
  message?: string;
}

export interface TaskError {
  message: string;
  code?: string;
}

export interface PendingApproval {
  approvalId: string;
  action: string;
  details?: Record<string, unknown>;
  requestedAt: string;
}

export type TaskHistoryKind =
  | "created"
  | "followup"
  | "progress"
  | "approval_requested"
  | "approval_resolved"
  | "terminal";

export interface TaskHistoryEntry {
  at: string;
  kind: TaskHistoryKind;
  message: string;
}

export interface Task {
  id: string;
  /** Client-session ownership scope used by auth, task listing, and SSE. */
  hermesSessionId: string;
  /** Hermes conversation scope for this coherent task and its follow-ups. */
  hermesThreadId: string;
  status: TaskStatus;
  instruction: string;
  clientRequestId?: string;
  summary?: string;
  progress?: TaskProgress;
  result?: unknown;
  error?: TaskError;
  pendingApproval?: PendingApproval;
  createdAt: string;
  updatedAt: string;
  history: TaskHistoryEntry[];
}

export const TERMINAL_STATUSES: ReadonlySet<TaskStatus> = new Set([
  "completed",
  "failed",
  "canceled",
]);

export function isTerminal(status: TaskStatus): boolean {
  return TERMINAL_STATUSES.has(status);
}
