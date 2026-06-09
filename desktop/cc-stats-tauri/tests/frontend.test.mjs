import test from "node:test";
import assert from "node:assert/strict";

import {
  dashboardUrl,
  normalizeApiBaseUrl,
  statusLabel,
} from "../src/dashboard.js";

test("normalizeApiBaseUrl trims trailing slash", () => {
  assert.equal(normalizeApiBaseUrl("http://127.0.0.1:61234/"), "http://127.0.0.1:61234");
});

test("dashboardUrl points at the Python dashboard root", () => {
  assert.equal(dashboardUrl("http://127.0.0.1:61234/"), "http://127.0.0.1:61234/");
});

test("statusLabel maps api process states", () => {
  assert.equal(statusLabel("starting"), "Starting API...");
  assert.equal(statusLabel("running"), "API running");
  assert.equal(statusLabel("failed"), "API failed");
  assert.equal(statusLabel("unknown"), "Unknown status");
});
