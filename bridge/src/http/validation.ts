import { z } from "zod";

// Generous but finite caps: enough for real voice-dictated instructions and
// follow-ups, small enough that no single request can be used to grow
// server memory or a downstream Hermes payload without bound. See
// docs/SECURITY.md.
export const LIMITS = {
  instruction: 4000,
  message: 4000,
  reason: 1000,
  note: 1000,
  clientRequestId: 128,
  approvalId: 128,
  voice: 64,
  taskId: 128,
  contextJsonLength: 8000,
} as const;

const contextSchema = z.unknown().refine(
  (value) => {
    if (value === undefined) return true;
    try {
      return JSON.stringify(value).length <= LIMITS.contextJsonLength;
    } catch {
      return false;
    }
  },
  { message: `context must serialize to at most ${LIMITS.contextJsonLength} JSON characters` }
);

export const createTaskSchema = z.object({
  instruction: z.string().min(1, "instruction must not be empty").max(LIMITS.instruction),
  context: contextSchema.optional(),
  clientRequestId: z.string().min(1).max(LIMITS.clientRequestId).optional(),
});

export const followupSchema = z.object({
  message: z.string().min(1, "message must not be empty").max(LIMITS.message),
});

export const cancelSchema = z.object({
  reason: z.string().min(1).max(LIMITS.reason).optional(),
});

export const approveSchema = z.object({
  approvalId: z.string().min(1).max(LIMITS.approvalId),
  decision: z.enum(["approve", "reject"]),
  note: z.string().min(1).max(LIMITS.note).optional(),
});

export const realtimeSessionSchema = z.object({
  voice: z.string().min(1).max(LIMITS.voice).optional(),
});

/** `task_<uuid>`-shaped, and bounded — guards the path param, not just bodies. */
export const taskIdSchema = z
  .string()
  .min(1)
  .max(LIMITS.taskId)
  .regex(/^[A-Za-z0-9_-]+$/, "taskId must be alphanumeric with - or _");
