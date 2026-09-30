"""Permission metadata shared by hooks and bridge ingestion."""

from typing import Any, Mapping


def _permission_mode_from_event(event: Mapping[str, Any]) -> str:
    for key in ("permission_mode", "permissionMode"):
        value = event.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    meta = event.get("meta")
    if isinstance(meta, Mapping):
        for key in ("permission_mode", "permissionMode"):
            value = meta.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
    permissions = event.get("permissions")
    if isinstance(permissions, Mapping):
        value = permissions.get("mode")
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""


def _is_bypass_permission_mode(event: Mapping[str, Any]) -> bool:
    mode = _permission_mode_from_event(event)
    normalized = mode.replace("_", "").replace("-", "").lower()
    return normalized.startswith("bypass")


