#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${1:-http://localhost:2026}"
MAX_ATTEMPTS=3
RETRY_INTERVAL_SECONDS=5
READINESS_ATTEMPTS=4
READINESS_URL="${BASE_URL}/"

ROUTES=(
  "/"
  "/workspace"
  "/workspace/chats/"
  "/workspace/chats/new"
  "/workspace/agents"
  "/workspace/agents/new"
)

echo "Waiting for frontend readiness at ${READINESS_URL}..."

readiness_attempt=1
while true; do
  if curl -fsS -o /dev/null "$READINESS_URL"; then
    break
  fi

  if [ "$readiness_attempt" -ge "$READINESS_ATTEMPTS" ]; then
    echo "warning: frontend readiness check failed for ${READINESS_URL} after ${READINESS_ATTEMPTS} attempts" >&2
    exit 1
  fi

  echo "  readiness retry in ${RETRY_INTERVAL_SECONDS}s (attempt ${readiness_attempt}/${READINESS_ATTEMPTS})..." >&2
  sleep "$RETRY_INTERVAL_SECONDS"
  readiness_attempt=$((readiness_attempt + 1))
done

echo "Prewarming frontend routes from ${BASE_URL}..."

for route in "${ROUTES[@]}"; do
  url="${BASE_URL}${route}"
  echo "  -> ${route}"
  attempt=1
  while true; do
    if curl -fsS -o /dev/null "$url"; then
      break
    fi

    if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
      echo "     warning: failed to prewarm ${url} after ${MAX_ATTEMPTS} attempts" >&2
      break
    fi

    echo "     retrying in ${RETRY_INTERVAL_SECONDS}s (attempt ${attempt}/${MAX_ATTEMPTS})..." >&2
    sleep "$RETRY_INTERVAL_SECONDS"
    attempt=$((attempt + 1))
  done
done

echo "Frontend prewarm finished."
