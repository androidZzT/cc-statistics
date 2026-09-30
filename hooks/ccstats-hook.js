#!/usr/bin/env node
// cc-statistics — Claude Code Hook Script
// Writes current state to ~/.cc-stats/activity-state.json
// Zero dependencies, zero network, fast cold start

const fs = require("fs");
const path = require("path");
const os = require("os");

let event = process.argv[2];
if (!event) process.exit(0);

const EVENT_TO_STATE = {
  UserPromptSubmit: "active",
  PreToolUse: "active",
  PostToolUse: "active",
  PostToolUseFailure: "active",
  SubagentStart: "active",
  SubagentStop: "active",
  PreCompact: "active",
  PostCompact: "active",
  Notification: "active",
  Elicitation: "active",
  WorktreeCreate: "active",
  PermissionRequest: "active",
  PermissionDenied: "active",
  Stop: "idle",
  StopFailure: "idle",
  SessionStart: "idle",
  SessionEnd: "idle",
};

let payload = {};
try {
  const input = JSON.parse(fs.readFileSync(0, "utf8"));
  if (input && typeof input === "object" && !Array.isArray(input)) payload = input;
} catch {}
const mode = [payload.permission_mode, payload.permissionMode,
  payload.meta?.permission_mode, payload.meta?.permissionMode, payload.permissions?.mode]
  .find(value => typeof value === "string" && value.trim()) || "";
const bypass = mode.trim().replace(/[_-]/g, "").toLowerCase().startsWith("bypass");
if (event === "PermissionRequest" && bypass) event = "PreToolUse";
const state = event === "Notification" && payload.notification_type === "idle_prompt"
  ? "idle" : EVENT_TO_STATE[event];
if (!state) process.exit(0);

const STATE_DIR = path.join(os.homedir(), ".cc-stats");
const STATE_FILE = path.join(STATE_DIR, "activity-state.json");

try {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  fs.writeFileSync(STATE_FILE, JSON.stringify({
    state,
    event,
    timestamp: Date.now(),
    approval_required: event === "PermissionRequest",
    session_id: typeof payload.session_id === "string" ? payload.session_id : "",
    notification_type: payload.notification_type,
  }));
} catch {}

process.exit(0);
