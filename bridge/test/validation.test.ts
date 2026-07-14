import { test } from "node:test";
import assert from "node:assert/strict";
import {
  createTaskSchema,
  followupSchema,
  cancelSchema,
  approveSchema,
  realtimeSessionSchema,
} from "../src/http/validation.js";

test("createTaskSchema requires a non-empty instruction", () => {
  assert.equal(createTaskSchema.safeParse({ instruction: "do it" }).success, true);
  assert.equal(createTaskSchema.safeParse({ instruction: "" }).success, false);
  assert.equal(createTaskSchema.safeParse({}).success, false);
  assert.equal(createTaskSchema.safeParse({ instruction: "x", context: { a: 1 } }).success, true);
});

test("followupSchema requires a non-empty message", () => {
  assert.equal(followupSchema.safeParse({ message: "hi" }).success, true);
  assert.equal(followupSchema.safeParse({ message: "" }).success, false);
});

test("cancelSchema allows an omitted reason", () => {
  assert.equal(cancelSchema.safeParse({}).success, true);
  assert.equal(cancelSchema.safeParse({ reason: "nvm" }).success, true);
});

test("approveSchema requires approvalId and a valid decision enum", () => {
  assert.equal(approveSchema.safeParse({ approvalId: "appr_1", decision: "approve" }).success, true);
  assert.equal(approveSchema.safeParse({ approvalId: "appr_1", decision: "reject" }).success, true);
  assert.equal(approveSchema.safeParse({ approvalId: "appr_1", decision: "maybe" }).success, false);
  assert.equal(approveSchema.safeParse({ decision: "approve" }).success, false);
});

test("realtimeSessionSchema allows an empty body and an optional voice", () => {
  assert.equal(realtimeSessionSchema.safeParse({}).success, true);
  assert.equal(realtimeSessionSchema.safeParse({ voice: "marin" }).success, true);
  assert.equal(realtimeSessionSchema.safeParse({ voice: 123 }).success, false);
});
