export function normalizeApiBaseUrl(url) {
  return String(url || "").replace(/\/+$/, "");
}

export function dashboardUrl(apiBaseUrl) {
  const base = normalizeApiBaseUrl(apiBaseUrl);
  return base ? `${base}/` : "";
}

export function statusLabel(status) {
  switch (status) {
    case "starting":
      return "Starting API...";
    case "running":
      return "API running";
    case "failed":
      return "API failed";
    case "stopped":
      return "API stopped";
    default:
      return "Unknown status";
  }
}
