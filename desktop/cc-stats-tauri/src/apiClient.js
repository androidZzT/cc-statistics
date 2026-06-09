import { invoke } from "@tauri-apps/api/core";

export async function apiStatus() {
  return invoke("api_status");
}

export async function restartApi() {
  return invoke("restart_api");
}

export async function openDashboard() {
  return invoke("open_dashboard");
}
