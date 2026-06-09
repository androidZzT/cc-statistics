import test from "node:test";
import assert from "node:assert/strict";

import {
  dashboardUrl,
  frameUrlForStatus,
  normalizeApiBaseUrl,
  STATUS_POLL_INTERVAL_MS,
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

test("statusLabel includes api errors for failed state", () => {
  assert.equal(
    statusLabel("failed", "python module missing"),
    "API failed: python module missing",
  );
});

test("frameUrlForStatus clears stale dashboard on api failure", () => {
  assert.equal(frameUrlForStatus({ state: "failed", url: "http://127.0.0.1:61234/" }), "");
  assert.equal(
    frameUrlForStatus({ state: "running", url: "http://127.0.0.1:61234/" }),
    "http://127.0.0.1:61234/",
  );
});

test("status polling interval is responsive without hammering the api", () => {
  assert.equal(STATUS_POLL_INTERVAL_MS, 3000);
});
