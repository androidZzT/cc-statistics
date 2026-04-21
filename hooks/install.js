#!/usr/bin/env node
// cc-statistics — Hook Installer
// Registers ccstats-hook.js into ~/.claude/settings.json
// Safe: appends to hook arrays, does not overwrite existing hooks

const fs = require("fs");
const path = require("path");
const os = require("os");

const HOOK_EVENTS = [
  "UserPromptSubmit",
  "PreToolUse",
  "PostToolUse",
  "PostToolUseFailure",
  "Stop",
  "SubagentStart",
  "SubagentStop",
  "Notification",
  "Elicitation",
  "WorktreeCreate",
  "PermissionRequest",
  "PermissionDenied",
  "SessionStart",
  "SessionEnd",
];

const HOOK_SCRIPT = path.resolve(__dirname, "ccstats-hook.js");
const SETTINGS_PATH = path.join(os.homedir(), ".claude", "settings.json");
const HOOK_MARKER = "ccstats-hook.js";

function buildCommand(event) {
  return `node ${HOOK_SCRIPT} ${event}`;
}

function install() {
  let settings = {};
  try {
    settings = JSON.parse(fs.readFileSync(SETTINGS_PATH, "utf8"));
  } catch {
    // No settings file yet
  }

  if (!settings.hooks) settings.hooks = {};

  let added = 0;
  let updated = 0;

  for (const event of HOOK_EVENTS) {
    if (!settings.hooks[event]) settings.hooks[event] = [];
    const hooks = settings.hooks[event];

    // Find existing ccstats hook
    const existingIdx = hooks.findIndex(
      (h) => typeof h === "object" && h.command && h.command.includes(HOOK_MARKER)
    );

    const hookEntry = {
      hooks: [{
        type: "command",
        command: buildCommand(event),
      }],
    };

    if (existingIdx >= 0) {
      const existingCmd = (hooks[existingIdx].hooks || [{}])[0].command || hooks[existingIdx].command;
      const newCmd = hookEntry.hooks[0].command;
      if (existingCmd !== newCmd) {
        hooks[existingIdx] = hookEntry;
        updated++;
      }
    } else {
      hooks.push(hookEntry);
      added++;
    }
  }

  fs.writeFileSync(SETTINGS_PATH, JSON.stringify(settings, null, 2) + "\n");
  console.log(`cc-stats hooks: added ${added}, updated ${updated} (${HOOK_EVENTS.length} events)`);
}

function uninstall() {
  let settings = {};
  try {
    settings = JSON.parse(fs.readFileSync(SETTINGS_PATH, "utf8"));
  } catch {
    console.log("No settings file found.");
    return;
  }

  if (!settings.hooks) return;

  let removed = 0;
  for (const event of Object.keys(settings.hooks)) {
    const hooks = settings.hooks[event];
    if (!Array.isArray(hooks)) continue;
    const before = hooks.length;
    settings.hooks[event] = hooks.filter((h) => {
      if (typeof h !== "object") return true;
      // Match flat format
      if (h.command && h.command.includes(HOOK_MARKER)) return false;
      // Match nested format
      if (Array.isArray(h.hooks)) {
        return !h.hooks.some((nh) => nh.command && nh.command.includes(HOOK_MARKER));
      }
      return true;
    });
    removed += before - settings.hooks[event].length;
    // Clean up empty arrays
    if (settings.hooks[event].length === 0) {
      delete settings.hooks[event];
    }
  }

  fs.writeFileSync(SETTINGS_PATH, JSON.stringify(settings, null, 2) + "\n");
  console.log(`cc-stats hooks: removed ${removed}`);
}

const cmd = process.argv[2] || "install";
if (cmd === "uninstall" || cmd === "remove") {
  uninstall();
} else {
  install();
}
