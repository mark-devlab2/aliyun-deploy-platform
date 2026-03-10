#!/bin/sh
set -eu

PLATFORM_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SERVICE_ID=""
TARGET=""
IMAGE_TAG=""
SKIP_HEALTH=0
HEALTH_MAX_WAIT_SECONDS="${HEALTH_MAX_WAIT_SECONDS:-60}"
HEALTH_RETRY_INTERVAL_SECONDS="${HEALTH_RETRY_INTERVAL_SECONDS:-5}"

usage() {
  cat >&2 <<'EOF'
usage: deploy-service.sh --service-id <id> --target <target> --image-tag <sha-...> [options]

options:
  --platform-dir <path>
  --service-id <id>
  --target <api|admin-web|full>
  --image-tag <sha-...>
  --skip-health
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --platform-dir)
      PLATFORM_DIR="$2"
      shift 2
      ;;
    --service-id)
      SERVICE_ID="$2"
      shift 2
      ;;
    --target)
      TARGET="$2"
      shift 2
      ;;
    --image-tag)
      IMAGE_TAG="$2"
      shift 2
      ;;
    --skip-health)
      SKIP_HEALTH=1
      shift 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [ -z "$SERVICE_ID" ] || [ -z "$TARGET" ] || [ -z "$IMAGE_TAG" ]; then
  usage
  exit 1
fi

DEPLOY_FILE="$PLATFORM_DIR/services/$SERVICE_ID/deploy.yaml"
if [ ! -f "$DEPLOY_FILE" ]; then
  echo "deploy contract not found: $DEPLOY_FILE" >&2
  exit 1
fi

DEPLOY_JSON="$(python3 "$PLATFORM_DIR/scripts/render-config.py" deploy-contract "$DEPLOY_FILE")"
DEPLOY_JSON_FILE="$(mktemp)"
printf '%s' "$DEPLOY_JSON" >"$DEPLOY_JSON_FILE"
RUNTIME_DIR="$PLATFORM_DIR/runtime/$SERVICE_ID"
SERVICE_ENV_FILE="$RUNTIME_DIR/service.env"
COMPOSE_ENV_FILE="$RUNTIME_DIR/compose.env"
RELEASE_DIR="$RUNTIME_DIR/releases"
CURRENT_RELEASE_FILE="$RELEASE_DIR/current.json"
PREVIOUS_RELEASE_FILE="$RELEASE_DIR/previous.json"
mkdir -p "$RELEASE_DIR"

if [ ! -f "$SERVICE_ENV_FILE" ]; then
  echo "service env file missing: $SERVICE_ENV_FILE" >&2
  exit 1
fi

if grep -Eq 'replace_with_|=cli_xxx$' "$SERVICE_ENV_FILE"; then
  echo "service env file still contains placeholder values: $SERVICE_ENV_FILE" >&2
  exit 1
fi

if [ -n "${GHCR_USERNAME:-}" ] && [ -n "${GHCR_TOKEN:-}" ]; then
  printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin >/dev/null
fi

PROJECT_NAME="$(python3 - "$DEPLOY_JSON_FILE" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], "r", encoding="utf-8"))["projectName"])
PY
)"
COMPOSE_FILE_REL="$(python3 - "$DEPLOY_JSON_FILE" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], "r", encoding="utf-8"))["composeFile"])
PY
)"
COMPOSE_FILE="$PLATFORM_DIR/$COMPOSE_FILE_REL"

API_IMAGE_REPO="$(python3 - "$DEPLOY_JSON_FILE" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], "r", encoding="utf-8"))["images"]["api"])
PY
)"
ADMIN_WEB_IMAGE_REPO="$(python3 - "$DEPLOY_JSON_FILE" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], "r", encoding="utf-8"))["images"]["admin-web"])
PY
)"
PULL_SERVICES="$(python3 - "$DEPLOY_JSON_FILE" "$TARGET" <<'PY'
import json
import sys

doc = json.load(open(sys.argv[1], "r", encoding="utf-8"))
target = sys.argv[2]
services = doc["targets"][target]["pullServices"]
print(" ".join(services))
PY
)"
UP_SERVICES="$(python3 - "$DEPLOY_JSON_FILE" "$TARGET" <<'PY'
import json
import sys

doc = json.load(open(sys.argv[1], "r", encoding="utf-8"))
target = sys.argv[2]
services = doc["targets"][target]["upServices"]
print(" ".join(services))
PY
)"
RUN_PRISMA="$(python3 - "$DEPLOY_JSON_FILE" "$TARGET" <<'PY'
import json
import sys

doc = json.load(open(sys.argv[1], "r", encoding="utf-8"))
target = sys.argv[2]
print("1" if doc["targets"][target].get("runPrisma") else "0")
PY
)"
HEALTH_URLS="$(python3 - "$DEPLOY_JSON_FILE" "$TARGET" <<'PY'
import json
import sys

doc = json.load(open(sys.argv[1], "r", encoding="utf-8"))
target = sys.argv[2]
for url in doc["targets"][target].get("healthChecks", []):
    print(url)
PY
)"

cat "$SERVICE_ENV_FILE" >"$COMPOSE_ENV_FILE"
{
  printf '\nAPI_IMAGE=%s:%s\n' "$API_IMAGE_REPO" "$IMAGE_TAG"
  printf 'ADMIN_WEB_IMAGE=%s:%s\n' "$ADMIN_WEB_IMAGE_REPO" "$IMAGE_TAG"
} >>"$COMPOSE_ENV_FILE"

compose_cmd() {
  docker compose -p "$PROJECT_NAME" --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

run_health_checks() {
  if [ -z "$HEALTH_URLS" ]; then
    return 0
  fi

  max_attempts=$((HEALTH_MAX_WAIT_SECONDS / HEALTH_RETRY_INTERVAL_SECONDS))
  if [ "$max_attempts" -lt 1 ]; then
    max_attempts=1
  fi

  attempt=1
  while [ "$attempt" -le "$max_attempts" ]; do
    passed=1
    while IFS= read -r url; do
      [ -n "$url" ] || continue
      if ! curl --connect-timeout 5 --max-time 20 -fsS "$url" >/dev/null; then
        passed=0
        break
      fi
    done <<EOF
$HEALTH_URLS
EOF

    if [ "$passed" -eq 1 ]; then
      echo "MILESTONE health checks passed attempt=$attempt"
      return 0
    fi

    if [ "$attempt" -lt "$max_attempts" ]; then
      sleep "$HEALTH_RETRY_INTERVAL_SECONDS"
    fi
    attempt=$((attempt + 1))
  done

  echo "health checks failed for $SERVICE_ID target=$TARGET after ${HEALTH_MAX_WAIT_SECONDS}s" >&2
  exit 1
}

echo "STARTED deploy service_id=$SERVICE_ID target=$TARGET image_tag=$IMAGE_TAG"
compose_cmd pull $PULL_SERVICES
compose_cmd up -d $UP_SERVICES

if [ "$RUN_PRISMA" = "1" ]; then
  compose_cmd exec -T api npx prisma db push
  echo "MILESTONE prisma db push completed"
fi

if [ "$SKIP_HEALTH" -eq 0 ]; then
  run_health_checks
else
  echo "MILESTONE health checks skipped"
fi

if [ -f "$CURRENT_RELEASE_FILE" ]; then
  cp "$CURRENT_RELEASE_FILE" "$PREVIOUS_RELEASE_FILE"
fi

DEPLOYED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
PLATFORM_COMMIT="$(git -C "$PLATFORM_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
SNAPSHOT_FILE="$RELEASE_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$IMAGE_TAG.json"

python3 - "$CURRENT_RELEASE_FILE" "$SNAPSHOT_FILE" "$DEPLOYED_AT" "$SERVICE_ID" "$TARGET" "$IMAGE_TAG" "$API_IMAGE_REPO:$IMAGE_TAG" "$ADMIN_WEB_IMAGE_REPO:$IMAGE_TAG" "$PLATFORM_COMMIT" <<'PY'
import json
import sys

current_path = sys.argv[1]
snapshot_path = sys.argv[2]
payload = {
    "deployedAt": sys.argv[3],
    "serviceId": sys.argv[4],
    "target": sys.argv[5],
    "imageTag": sys.argv[6],
    "images": {
        "api": sys.argv[7],
        "admin-web": sys.argv[8],
    },
    "platformCommit": sys.argv[9],
}

for path in (current_path, snapshot_path):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=True, indent=2)
        fh.write("\n")
PY

rm -f "$DEPLOY_JSON_FILE"

echo "SUMMARY service_id=$SERVICE_ID target=$TARGET image_tag=$IMAGE_TAG platform_commit=$PLATFORM_COMMIT"
