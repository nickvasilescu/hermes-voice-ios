import { Router, type Request, type Response } from "express";
import type { TaskService } from "../../tasks/service.js";
import type { TaskStatus } from "../../types.js";
import { TERMINAL_STATUSES } from "../../types.js";
import { asyncHandler } from "../asyncHandler.js";
import { approveSchema, cancelSchema, createTaskSchema, followupSchema, taskIdSchema } from "../validation.js";

const KNOWN_STATUSES: ReadonlySet<string> = new Set([
  "queued",
  "running",
  "waiting_approval",
  ...TERMINAL_STATUSES,
]);

/** Returns the validated taskId, or writes a 400 and returns undefined. */
function requireValidTaskId(req: Request, res: Response): string | undefined {
  const parsed = taskIdSchema.safeParse(req.params.taskId);
  if (!parsed.success) {
    res.status(400).json({ error: "validation_error", detail: "invalid taskId" });
    return undefined;
  }
  return parsed.data;
}

export function tasksRouter(taskService: TaskService): Router {
  const router = Router();

  router.post(
    "/tasks",
    asyncHandler(async (req, res) => {
      const parsed = createTaskSchema.safeParse(req.body ?? {});
      if (!parsed.success) {
        res.status(400).json({ error: "validation_error", detail: parsed.error.message });
        return;
      }
      const { task, created } = taskService.createTask({ hermesSessionId: req.hermesSessionId, ...parsed.data });
      res.status(created ? 201 : 200).json(task);
    })
  );

  router.get(
    "/tasks",
    asyncHandler(async (req, res) => {
      const statusParam = typeof req.query.status === "string" ? req.query.status : undefined;
      if (statusParam && !KNOWN_STATUSES.has(statusParam)) {
        res.status(400).json({ error: "validation_error", detail: `Unknown status ${statusParam}` });
        return;
      }
      const tasks = taskService.listTasks(req.hermesSessionId, statusParam as TaskStatus | undefined);
      res.status(200).json({ tasks });
    })
  );

  router.get(
    "/tasks/:taskId",
    asyncHandler(async (req, res) => {
      const taskId = requireValidTaskId(req, res);
      if (!taskId) return;
      const task = taskService.getTask(req.hermesSessionId, taskId);
      res.status(200).json(task);
    })
  );

  router.post(
    "/tasks/:taskId/followup",
    asyncHandler(async (req, res) => {
      const taskId = requireValidTaskId(req, res);
      if (!taskId) return;
      const parsed = followupSchema.safeParse(req.body ?? {});
      if (!parsed.success) {
        res.status(400).json({ error: "validation_error", detail: parsed.error.message });
        return;
      }
      const task = await taskService.followup(req.hermesSessionId, taskId, parsed.data.message);
      res.status(200).json(task);
    })
  );

  router.post(
    "/tasks/:taskId/cancel",
    asyncHandler(async (req, res) => {
      const taskId = requireValidTaskId(req, res);
      if (!taskId) return;
      const parsed = cancelSchema.safeParse(req.body ?? {});
      if (!parsed.success) {
        res.status(400).json({ error: "validation_error", detail: parsed.error.message });
        return;
      }
      const task = await taskService.cancel(req.hermesSessionId, taskId, parsed.data.reason);
      res.status(200).json(task);
    })
  );

  router.post(
    "/tasks/:taskId/approve",
    asyncHandler(async (req, res) => {
      const taskId = requireValidTaskId(req, res);
      if (!taskId) return;
      const parsed = approveSchema.safeParse(req.body ?? {});
      if (!parsed.success) {
        res.status(400).json({ error: "validation_error", detail: parsed.error.message });
        return;
      }
      const task = await taskService.approve(
        req.hermesSessionId,
        taskId,
        parsed.data.approvalId,
        parsed.data.decision,
        parsed.data.note
      );
      res.status(200).json(task);
    })
  );

  return router;
}
