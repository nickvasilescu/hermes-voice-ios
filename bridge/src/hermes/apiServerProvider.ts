import { randomUUID } from "node:crypto";
import { TTLMap } from "../util/ttlMap.js";
import {
  HermesProviderError,
  type CreateTaskInput,
  type HermesProvider,
  type HermesProviderEvent,
  type HermesProviderListener,
} from "./provider.js";

export interface ApiServerHermesProviderOptions {
  /** Base URL of the Hermes API Server, e.g. `http://127.0.0.1:8642`. */
  baseUrl: string;
  /** Bearer token matching `API_SERVER_KEY` on the Hermes host. */
  apiKey: string;
  /** Injectable fetch for tests. */
  fetchImpl?: typeof fetch;
  /**
   * Optional extra instructions layered onto Hermes' system prompt for
   * every run started by this provider.
   */
  instructions?: string;
  /** Hard cap on internally-tracked tasks; oldest-touched evicted first. */
  maxEntries?: number;
  /** How long an internal task record lives since it was last touched. */
  ttlMs?: number;
  /**
   * How long a terminal task record is kept before proactive deletion —
   * shorter than `ttlMs` on purpose (same rationale as MockHermesProvider).
   */
  terminalRetentionMs?: number;
  clock?: () => number;
}

interface ConversationMessage {
  role: string;
  content: string;
}

interface InternalTask {
  hermesSessionId: string;
  instruction: string;
  context?: unknown;
  terminal: boolean;
  runId?: string;
  pendingApprovalId?: string;
  conversationHistory: ConversationMessage[];
  pendingFollowups: string[];
  /** Input string that started the active Hermes run (for history stitching). */
  currentInput?: string;
  lastOutput?: string;
  sseAbort?: AbortController;
  startingRun: boolean;
  /** Set by cancelTask so a run that returns mid-startup is stopped. */
  cancelRequested: boolean;
}

const DEFAULT_MAX_ENTRIES = 5000;
const DEFAULT_TTL_MS = 24 * 60 * 60 * 1000;
const DEFAULT_TERMINAL_RETENTION_MS = 5 * 60 * 1000;

/**
 * Real Hermes integration against the Hermes API Server runs API
 * (`POST /v1/runs`, SSE `/events`, `/stop`, `/approval`).
 *
 * Bridge `taskId` is local; Hermes assigns `run_id`. One bridge task may
 * span multiple Hermes runs when follow-ups arrive before the task is
 * considered finished (queued follow-ups drain as successive runs on the
 * same `session_id`).
 */
export class ApiServerHermesProvider implements HermesProvider {
  private readonly baseUrl: string;
  private readonly apiKey: string;
  private readonly fetchImpl: typeof fetch;
  private readonly instructions: string | undefined;
  private readonly terminalRetentionMs: number;
  private readonly tasks: TTLMap<string, InternalTask>;
  private readonly runIdToTaskId: TTLMap<string, string>;
  private readonly listeners = new Set<HermesProviderListener>();

  constructor(options: ApiServerHermesProviderOptions) {
    if (!options.baseUrl?.trim()) {
      throw new Error("ApiServerHermesProvider requires baseUrl");
    }
    if (!options.apiKey?.trim()) {
      throw new Error("ApiServerHermesProvider requires apiKey");
    }
    this.baseUrl = options.baseUrl.replace(/\/+$/, "");
    this.apiKey = options.apiKey;
    this.fetchImpl = options.fetchImpl ?? fetch;
    this.instructions = options.instructions;
    this.terminalRetentionMs = options.terminalRetentionMs ?? DEFAULT_TERMINAL_RETENTION_MS;
    const ttlOpts = {
      maxEntries: options.maxEntries ?? DEFAULT_MAX_ENTRIES,
      ttlMs: options.ttlMs ?? DEFAULT_TTL_MS,
      clock: options.clock,
    };
    this.tasks = new TTLMap(ttlOpts);
    this.runIdToTaskId = new TTLMap(ttlOpts);
  }

  onEvent(listener: HermesProviderListener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  async createTask(input: CreateTaskInput): Promise<void> {
    if (this.tasks.get(input.taskId)) {
      throw new HermesProviderError("task_already_exists", `Task already exists: ${input.taskId}`);
    }

    const internal: InternalTask = {
      hermesSessionId: input.hermesSessionId,
      instruction: input.instruction,
      context: input.context,
      terminal: false,
      conversationHistory: [],
      pendingFollowups: [],
      startingRun: false,
      cancelRequested: false,
    };
    this.tasks.set(input.taskId, internal);

    this.emit({ type: "status", taskId: input.taskId, status: "running" });
    await this.startRun(input.taskId, input.instruction, []);
  }

  async sendFollowup(taskId: string, message: string): Promise<void> {
    const internal = this.requireTask(taskId);
    if (internal.terminal) throw new HermesProviderError("task_terminal");

    internal.pendingFollowups.push(message);
    this.emit({
      type: "progress",
      taskId,
      message: `Follow-up queued: ${message}`,
    });

    // If no run is in flight, drain immediately as the next turn.
    if (!internal.runId && !internal.startingRun) {
      await this.drainFollowups(taskId);
    }
  }

  async cancelTask(taskId: string, _reason?: string): Promise<void> {
    const internal = this.requireTask(taskId);
    if (internal.terminal) throw new HermesProviderError("task_terminal");

    internal.cancelRequested = true;
    internal.pendingFollowups = [];
    const runId = internal.runId;
    if (runId) {
      try {
        await this.request("POST", `/v1/runs/${encodeURIComponent(runId)}/stop`, {});
      } catch (err) {
        // Run already finished / unknown — still settle as canceled locally.
        if (!this.isBenignStopMiss(err)) throw err;
      }
    }

    this.markTerminal(taskId, internal);
    internal.sseAbort?.abort();
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
    if (internal.pendingApprovalId !== approvalId || !internal.runId) {
      throw new HermesProviderError("no_matching_approval");
    }

    const choice = decision === "approve" ? "once" : "deny";
    await this.request("POST", `/v1/runs/${encodeURIComponent(internal.runId)}/approval`, {
      choice,
    });
    internal.pendingApprovalId = undefined;
  }

  private async startRun(
    taskId: string,
    input: string,
    conversationHistory: ConversationMessage[]
  ): Promise<void> {
    const internal = this.requireTask(taskId);
    if (internal.terminal || internal.cancelRequested) return;

    internal.startingRun = true;
    try {
      const body: Record<string, unknown> = {
        input,
        session_id: internal.hermesSessionId,
      };
      if (conversationHistory.length > 0) {
        body.conversation_history = conversationHistory;
      }
      if (this.instructions) {
        body.instructions = this.instructions;
      }
      if (internal.context !== undefined) {
        // Hermes ignores unknown fields; keep context discoverable for
        // deployments that layer custom middleware, and fold a short note
        // into instructions when we already send some.
        body.voice_context = internal.context;
      }

      const response = await this.request<{ run_id: string; status: string }>(
        "POST",
        "/v1/runs",
        body,
        {
          "X-Hermes-Session-Key": internal.hermesSessionId,
        }
      );

      const runId = response.run_id;
      if (!runId) {
        throw new HermesProviderError("upstream_error", "Hermes /v1/runs returned no run_id");
      }

      // Cancel won the race while POST /v1/runs was in flight — stop the
      // orphaned Hermes run and do not attach SSE or register maps.
      if (internal.terminal || internal.cancelRequested) {
        try {
          await this.request("POST", `/v1/runs/${encodeURIComponent(runId)}/stop`, {});
        } catch (err) {
          if (!this.isBenignStopMiss(err)) {
            // Best-effort stop already attempted; surface only unexpected failures.
            throw err;
          }
        }
        return;
      }

      if (internal.runId) {
        this.runIdToTaskId.delete(internal.runId);
        internal.sseAbort?.abort();
      }
      internal.runId = runId;
      internal.currentInput = input;
      internal.pendingApprovalId = undefined;
      this.runIdToTaskId.set(runId, taskId);
      this.tasks.set(taskId, internal); // refresh TTL while run is live
      this.attachEventStream(taskId, runId);
    } finally {
      internal.startingRun = false;
    }
  }

  private attachEventStream(taskId: string, runId: string): void {
    const internal = this.tasks.get(taskId);
    if (!internal || internal.terminal) return;

    const abort = new AbortController();
    internal.sseAbort = abort;

    void this.consumeEventStream(taskId, runId, abort.signal).catch((err) => {
      if (abort.signal.aborted) return;
      const current = this.tasks.get(taskId);
      if (!current || current.terminal || current.runId !== runId) return;
      this.markTerminal(taskId, current);
      this.emit({
        type: "failed",
        taskId,
        error: {
          message: err instanceof Error ? err.message : String(err),
          code: err instanceof HermesProviderError ? err.code : "upstream_error",
        },
      });
    });
  }

  private async consumeEventStream(
    taskId: string,
    runId: string,
    signal: AbortSignal
  ): Promise<void> {
    const response = await this.fetchImpl(`${this.baseUrl}/v1/runs/${encodeURIComponent(runId)}/events`, {
      method: "GET",
      headers: {
        Authorization: `Bearer ${this.apiKey}`,
        Accept: "text/event-stream",
      },
      signal,
    });

    if (!response.ok) {
      throw await this.errorFromResponse(response, `/v1/runs/${runId}/events`);
    }
    if (!response.body) {
      throw new HermesProviderError("upstream_error", "Hermes SSE response had no body");
    }

    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });

      let splitAt: number;
      while ((splitAt = buffer.indexOf("\n\n")) >= 0) {
        const rawEvent = buffer.slice(0, splitAt);
        buffer = buffer.slice(splitAt + 2);
        const dataLines = rawEvent
          .split("\n")
          .filter((line) => line.startsWith("data:"))
          .map((line) => line.slice(5).trimStart());
        if (dataLines.length === 0) continue;
        let parsed: Record<string, unknown>;
        try {
          parsed = JSON.parse(dataLines.join("\n")) as Record<string, unknown>;
        } catch {
          continue;
        }
        this.handleRunEvent(taskId, runId, parsed);
      }
    }

    // Clean EOF without a terminal Hermes event (idle proxies like Cloudflare
    // do this) must not leave the task stuck `running` forever.
    const current = this.tasks.get(taskId);
    if (current && !current.terminal && current.runId === runId && !signal.aborted) {
      this.markTerminal(taskId, current);
      this.emit({
        type: "failed",
        taskId,
        error: {
          message: "Hermes run event stream closed before the run settled",
          code: "sse_closed_unexpectedly",
        },
      });
    }
  }

  private handleRunEvent(taskId: string, runId: string, event: Record<string, unknown>): void {
    const internal = this.tasks.get(taskId);
    if (!internal || internal.terminal || internal.runId !== runId) return;

    const type = String(event.event ?? "");

    switch (type) {
      case "tool.started": {
        const tool = String(event.tool ?? "tool");
        const preview = event.preview != null ? String(event.preview) : undefined;
        this.emit({
          type: "progress",
          taskId,
          message: preview ? `${tool}: ${preview}` : `Running ${tool}`,
        });
        break;
      }
      case "tool.completed": {
        const tool = String(event.tool ?? "tool");
        const erred = Boolean(event.error);
        this.emit({
          type: "progress",
          taskId,
          message: erred ? `${tool} failed` : `${tool} finished`,
        });
        break;
      }
      case "reasoning.available": {
        const text = String(event.text ?? "").trim();
        if (text) {
          this.emit({ type: "progress", taskId, message: text.slice(0, 500) });
        }
        break;
      }
      case "approval.request": {
        const approvalId = `appr_${randomUUID()}`;
        internal.pendingApprovalId = approvalId;
        const action =
          (typeof event.action === "string" && event.action) ||
          (typeof event.tool === "string" && event.tool) ||
          (typeof event.command === "string" && "shell_command") ||
          "approval_required";
        const details: Record<string, unknown> = {};
        for (const key of ["command", "description", "tool", "preview", "choices", "path"]) {
          if (key in event) details[key] = event[key];
        }
        this.emit({
          type: "approval_required",
          taskId,
          approvalId,
          action,
          details: Object.keys(details).length > 0 ? details : undefined,
        });
        break;
      }
      case "run.completed": {
        const output = typeof event.output === "string" ? event.output : "";
        internal.lastOutput = output;
        const userTurn = internal.currentInput ?? internal.instruction;
        internal.conversationHistory.push({ role: "user", content: userTurn });
        if (output) {
          internal.conversationHistory.push({ role: "assistant", content: output });
        }
        internal.currentInput = undefined;
        internal.runId = undefined;
        this.runIdToTaskId.delete(runId);
        internal.pendingApprovalId = undefined;

        void this.afterRunSettled(taskId, {
          kind: "completed",
          output,
          usage: event.usage,
        }).catch((err) => {
          const current = this.tasks.get(taskId);
          if (!current || current.terminal) return;
          this.markTerminal(taskId, current);
          this.emit({
            type: "failed",
            taskId,
            error: {
              message: err instanceof Error ? err.message : String(err),
              code: err instanceof HermesProviderError ? err.code : "upstream_error",
            },
          });
        });
        break;
      }
      case "run.failed": {
        internal.runId = undefined;
        this.runIdToTaskId.delete(runId);
        internal.pendingApprovalId = undefined;
        const message =
          typeof event.error === "string" && event.error.trim()
            ? event.error
            : "Hermes run failed";
        this.markTerminal(taskId, internal);
        this.emit({
          type: "failed",
          taskId,
          error: { message, code: "hermes_run_failed" },
        });
        break;
      }
      case "run.cancelled": {
        // cancelTask may have already emitted canceled; only settle once.
        if (internal.terminal) return;
        internal.runId = undefined;
        this.runIdToTaskId.delete(runId);
        internal.pendingApprovalId = undefined;
        this.markTerminal(taskId, internal);
        this.emit({ type: "canceled", taskId });
        break;
      }
      default:
        break;
    }
  }

  private async afterRunSettled(
    taskId: string,
    result: { kind: "completed"; output: string; usage: unknown }
  ): Promise<void> {
    const internal = this.tasks.get(taskId);
    if (!internal || internal.terminal) return;

    if (internal.pendingFollowups.length > 0) {
      this.emit({
        type: "progress",
        taskId,
        message: result.output ? result.output.slice(0, 500) : "Turn finished; continuing follow-up",
      });
      await this.drainFollowups(taskId);
      return;
    }

    this.markTerminal(taskId, internal);
    this.emit({
      type: "completed",
      taskId,
      result: { output: result.output, usage: result.usage },
      summary: result.output ? result.output.slice(0, 500) : "Done.",
    });
  }

  private async drainFollowups(taskId: string): Promise<void> {
    const internal = this.tasks.get(taskId);
    if (!internal || internal.terminal) return;
    if (internal.startingRun || internal.runId) return;

    const next = internal.pendingFollowups.shift();
    if (!next) return;

    // History for the next run is prior completed turns; current follow-up is input.
    const history = internal.conversationHistory.slice();
    await this.startRun(taskId, next, history);
  }

  private markTerminal(taskId: string, internal: InternalTask): void {
    internal.terminal = true;
    internal.startingRun = false;
    if (internal.runId) {
      this.runIdToTaskId.delete(internal.runId);
      internal.runId = undefined;
    }
    internal.sseAbort?.abort();
    internal.sseAbort = undefined;
    const cleanupTimer = setTimeout(() => {
      this.tasks.delete(taskId);
    }, this.terminalRetentionMs);
    cleanupTimer.unref?.();
  }

  private requireTask(taskId: string): InternalTask {
    const internal = this.tasks.get(taskId);
    if (!internal) throw new HermesProviderError("task_not_found");
    return internal;
  }

  private isBenignStopMiss(err: unknown): boolean {
    return (
      err instanceof HermesProviderError &&
      (err.code === "run_not_found" || err.code === "task_not_found")
    );
  }

  private emit(event: HermesProviderEvent): void {
    for (const listener of this.listeners) listener(event);
  }

  private async request<T>(
    method: string,
    path: string,
    body?: unknown,
    extraHeaders?: Record<string, string>
  ): Promise<T> {
    const response = await this.fetchImpl(`${this.baseUrl}${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${this.apiKey}`,
        Accept: "application/json",
        ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
        ...extraHeaders,
      },
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });

    if (!response.ok) {
      throw await this.errorFromResponse(response, path);
    }

    if (response.status === 204) return undefined as T;
    const text = await response.text();
    if (!text) return undefined as T;
    return JSON.parse(text) as T;
  }

  private async errorFromResponse(response: Response, path?: string): Promise<HermesProviderError> {
    let detail = response.statusText || `HTTP ${response.status}`;
    let code = "upstream_error";
    try {
      const json = (await response.json()) as {
        error?: { message?: string; code?: string } | string;
        code?: string;
        message?: string;
      };
      if (typeof json.error === "string") {
        detail = json.error;
      } else if (json.error && typeof json.error === "object") {
        detail = json.error.message ?? detail;
        code = json.error.code ?? code;
      } else if (typeof json.message === "string") {
        detail = json.message;
      }
      if (typeof json.code === "string") code = json.code;
    } catch {
      // keep defaults
    }

    if (response.status === 404 && code === "upstream_error") {
      // Run-scoped paths must not become task_not_found — cancel treats
      // run_not_found as "already gone" and still settles locally.
      code = path?.includes("/v1/runs/") ? "run_not_found" : "task_not_found";
    }
    if (response.status === 409 && code === "upstream_error") code = "task_terminal";

    return new HermesProviderError(code, detail);
  }
}
