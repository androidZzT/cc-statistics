#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8765}"
PORT="${PORT:-8765}"

echo "[1/3] starting bridge on ${BASE_URL} ..."
cc-stats-bridge --host 127.0.0.1 --port "${PORT}" >/tmp/cc-stats-bridge.log 2>&1 &
BRIDGE_PID=$!
trap 'kill ${BRIDGE_PID} >/dev/null 2>&1 || true' EXIT

for i in {1..20}; do
  if curl -sf "${BASE_URL}/v1/health" >/dev/null; then
    break
  fi
  sleep 0.2
done

echo "[2/3] seeding demo events ..."
python3 scripts/bridge_seed_events.py --base-url "${BASE_URL}"

echo "[3/3] bridge running (pid=${BRIDGE_PID}), log=/tmp/cc-stats-bridge.log"
echo "Tip: open iOS app and point bridge URL to ${BASE_URL}"
wait "${BRIDGE_PID}"
