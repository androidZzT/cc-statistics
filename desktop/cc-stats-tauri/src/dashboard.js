export const STATUS_POLL_INTERVAL_MS = 3000;

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

export function updateFrameForStatus(frameEl, status) {
  if (!frameEl) {
    return false;
  }
  const nextUrl = frameUrlForStatus(status);
  const currentUrl =
    typeof frameEl.getAttribute === "function"
      ? frameEl.getAttribute("src") || ""
      : frameEl.src || "";
  if (currentUrl === nextUrl) {
    return false;
  }
  if (nextUrl) {
    if (typeof frameEl.setAttribute === "function") {
      frameEl.setAttribute("src", nextUrl);
    } else {
      frameEl.src = nextUrl;
    }
  } else if (typeof frameEl.removeAttribute === "function") {
    frameEl.removeAttribute("src");
  } else {
    frameEl.src = "";
  }
  return true;
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
