export function normalizeApiBaseUrl(url) {
  return String(url || "").replace(/\/+$/, "");
}

export function dashboardUrl(apiBaseUrl) {
  const base = normalizeApiBaseUrl(apiBaseUrl);
  return base ? `${base}/` : "";
}

export function frameUrlForStatus(status) {
  if (status?.state !== "running") {
    return "";
  }
  return dashboardUrl(status.url);
}

export function statusLabel(status, error = "") {
  switch (status) {
    case "starting":
      return "Starting API...";
    case "running":
      return "API running";
    case "failed":
      return error ? `API failed: ${error}` : "API failed";
    case "stopped":
      return "API stopped";
    default:
      return "Unknown status";
  }
}
