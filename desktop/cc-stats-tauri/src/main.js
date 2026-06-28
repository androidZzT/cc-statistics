import { apiStatus, openDashboard, restartApi } from "./apiClient.js";
import { STATUS_POLL_INTERVAL_MS, statusLabel, updateFrameForStatus } from "./dashboard.js";

const statusEl = document.querySelector("[data-status]");
const frameEl = document.querySelector("[data-dashboard-frame]");
const openBtn = document.querySelector("[data-open-dashboard]");
const restartBtn = document.querySelector("[data-restart-api]");

async function refreshStatus() {
  const status = await apiStatus();
  statusEl.textContent = statusLabel(status.state, status.error);
  updateFrameForStatus(frameEl, status);
}

openBtn?.addEventListener("click", () => {
  openDashboard().then(refreshStatus).catch((error) => {
    statusEl.textContent = `Open failed: ${error}`;
  });
});

restartBtn?.addEventListener("click", () => {
  statusEl.textContent = statusLabel("starting");
  restartApi().then(refreshStatus).catch((error) => {
    statusEl.textContent = `Restart failed: ${error}`;
  });
});

refreshStatus().catch((error) => {
  statusEl.textContent = `Status unavailable: ${error}`;
});

setInterval(() => {
  refreshStatus().catch((error) => {
    statusEl.textContent = `Status unavailable: ${error}`;
  });
}, STATUS_POLL_INTERVAL_MS);
