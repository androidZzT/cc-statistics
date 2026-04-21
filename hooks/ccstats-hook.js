#!/usr/bin/env node
// cc-statistics — Claude Code Hook Script
// Writes current state to ~/.cc-stats/activity-state.json
// Zero dependencies, zero network, fast cold start

const fs = require("fs");
const path = require("path");
const os = require("os");

const event = process.argv[2];
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

const state = EVENT_TO_STATE[event];
if (!state) process.exit(0);

const STATE_DIR = path.join(os.homedir(), ".cc-stats");
const STATE_FILE = path.join(STATE_DIR, "activity-state.json");

try {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  fs.writeFileSync(STATE_FILE, JSON.stringify({
    state,
    event,
    timestamp: Date.now(),
  }));
} catch {}

process.exit(0);
