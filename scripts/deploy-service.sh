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
  --target <target>
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

case "$IMAGE_TAG" in
  sha-*)
    ;;
  *)
    echo "image tag must use sha-* format: $IMAGE_TAG" >&2
    exit 1
    ;;
esac

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
ATTEMPTS_DIR="$RELEASE_DIR/attempts"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
START_EPOCH="$(date +%s)"
ATTEMPT_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LAST_ATTEMPT_FILE="$RELEASE_DIR/last_attempt.json"
ATTEMPT_FILE="$ATTEMPTS_DIR/$ATTEMPT_STAMP-$IMAGE_TAG.json"
CURRENT_STEP="prepare"
PULL_DURATION_SECONDS=0
UP_DURATION_SECONDS=0
PRISMA_DURATION_SECONDS=0
HEALTH_DURATION_SECONDS=0
TOTAL_DURATION_SECONDS=0
HEALTH_SKIPPED=0
ATTEMPT_NOTE=""
IMAGE_SNAPSHOT_JSON='{}'
PRODUCTION_REGISTRY=""
PRODUCTION_REGISTRY_HOST=""
mkdir -p "$RELEASE_DIR" "$ATTEMPTS_DIR"

timestamp_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

write_attempt_files() {
  ended_at="$1"
  status="$2"
  note="$3"
  python3 - "$LAST_ATTEMPT_FILE" "$ATTEMPT_FILE" "$STARTED_AT" "$ended_at" "$status" "$SERVICE_ID" "$TARGET" "$IMAGE_TAG" "$IMAGE_SNAPSHOT_JSON" "$PLATFORM_COMMIT" "$PRODUCTION_REGISTRY" "$CURRENT_STEP" "$note" "$PULL_DURATION_SECONDS" "$UP_DURATION_SECONDS" "$PRISMA_DURATION_SECONDS" "$HEALTH_DURATION_SECONDS" "$TOTAL_DURATION_SECONDS" "$HEALTH_SKIPPED" <<'PY'
import json
import sys

payload = {
    "startedAt": sys.argv[3],
    "endedAt": sys.argv[4],
    "status": sys.argv[5],
    "serviceId": sys.argv[6],
    "target": sys.argv[7],
    "imageTag": sys.argv[8],
    "images": json.loads(sys.argv[9]),
    "platformCommit": sys.argv[10],
    "productionRegistry": sys.argv[11],
    "lastStep": sys.argv[12],
    "note": sys.argv[13],
    "durations": {
        "pullSeconds": int(sys.argv[14]),
        "upSeconds": int(sys.argv[15]),
        "prismaSeconds": int(sys.argv[16]),
        "healthSeconds": int(sys.argv[17]),
        "totalSeconds": int(sys.argv[18]),
    },
    "healthChecksSkipped": sys.argv[19] == "1",
}

for path in (sys.argv[1], sys.argv[2]):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=True, indent=2)
        fh.write("\n")
PY
}

finish_attempt() {
  exit_code="$1"
  ended_at="$(timestamp_utc)"
  TOTAL_DURATION_SECONDS=$(( $(date +%s) - START_EPOCH ))

  if [ "$exit_code" -eq 0 ]; then
    write_attempt_files "$ended_at" "success" "${ATTEMPT_NOTE:-deploy completed}"
  else
    if [ -z "$ATTEMPT_NOTE" ]; then
      ATTEMPT_NOTE="deploy failed at step=$CURRENT_STEP"
    fi
    write_attempt_files "$ended_at" "failed" "$ATTEMPT_NOTE"
    echo "FAILED service_id=$SERVICE_ID target=$TARGET image_tag=$IMAGE_TAG step=$CURRENT_STEP total_duration_seconds=$TOTAL_DURATION_SECONDS note=$ATTEMPT_NOTE" >&2
  fi

  rm -f "$DEPLOY_JSON_FILE"
}

trap 'finish_attempt $?' EXIT

PLATFORM_COMMIT="$(git -C "$PLATFORM_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"

if [ ! -f "$SERVICE_ENV_FILE" ]; then
  echo "service env file missing: $SERVICE_ENV_FILE" >&2
  exit 1
fi

if grep -Eq 'replace_with_|=cli_xxx$' "$SERVICE_ENV_FILE"; then
  echo "service env file still contains placeholder values: $SERVICE_ENV_FILE" >&2
  exit 1
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
PRODUCTION_REGISTRY="$(python3 - "$DEPLOY_JSON_FILE" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], "r", encoding="utf-8"))["productionRegistry"])
PY
)"
PRODUCTION_REGISTRY_HOST="$(python3 - "$DEPLOY_JSON_FILE" <<'PY'
import json
import sys

doc = json.load(open(sys.argv[1], "r", encoding="utf-8"))
first_image = next(iter(doc["images"].values()))
repository = first_image[doc["productionRegistry"]]
print(repository.split("/", 1)[0])
PY
)"
CURRENT_STEP="registry_login"
case "$PRODUCTION_REGISTRY_HOST" in
  ghcr.io)
    if [ -z "${GHCR_USERNAME:-}" ] || [ -z "${GHCR_TOKEN:-}" ]; then
      echo "missing GHCR credentials for production registry ghcr.io" >&2
      exit 1
    fi
    printf '%s' "$GHCR_TOKEN" | docker login "$PRODUCTION_REGISTRY_HOST" -u "$GHCR_USERNAME" --password-stdin >/dev/null
    ;;
  *.aliyuncs.com)
    if [ -z "${ACR_USERNAME:-}" ] || [ -z "${ACR_PASSWORD:-}" ]; then
      echo "missing ACR credentials for production registry $PRODUCTION_REGISTRY_HOST" >&2
      exit 1
    fi
    printf '%s' "$ACR_PASSWORD" | docker login "$PRODUCTION_REGISTRY_HOST" -u "$ACR_USERNAME" --password-stdin >/dev/null
    ;;
  *)
    echo "unsupported production registry host: $PRODUCTION_REGISTRY_HOST" >&2
    exit 1
    ;;
esac
IMAGE_ENV_LINES="$(python3 - "$DEPLOY_JSON_FILE" "$IMAGE_TAG" <<'PY'
import json
import re
import sys

doc = json.load(open(sys.argv[1], "r", encoding="utf-8"))
tag = sys.argv[2]
production_registry = doc["productionRegistry"]
for name, repositories in doc["images"].items():
    repository = repositories[production_registry]
    env_name = re.sub(r"[^A-Z0-9]+", "_", name.upper()) + "_IMAGE"
    print(f"{env_name}={repository}:{tag}")
PY
)"
IMAGE_SNAPSHOT_JSON="$(python3 - "$DEPLOY_JSON_FILE" "$IMAGE_TAG" <<'PY'
import json
import sys

doc = json.load(open(sys.argv[1], "r", encoding="utf-8"))
tag = sys.argv[2]
production_registry = doc["productionRegistry"]
images = {
    name: f"{repositories[production_registry]}:{tag}"
    for name, repositories in doc["images"].items()
}
print(json.dumps(images, ensure_ascii=True, separators=(",", ":")))
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
TCP_HEALTH_CHECKS="$(python3 - "$DEPLOY_JSON_FILE" "$TARGET" <<'PY'
import json
import sys

doc = json.load(open(sys.argv[1], "r", encoding="utf-8"))
target = sys.argv[2]
checks = doc["targets"][target].get("tcpHealthChecks")
if checks is None:
    checks = doc.get("tcpHealthChecks", [])
for value in checks:
    print(value)
PY
)"

cat "$SERVICE_ENV_FILE" >"$COMPOSE_ENV_FILE"
printf '\n' >>"$COMPOSE_ENV_FILE"
printf '%s\n' "$IMAGE_ENV_LINES" >>"$COMPOSE_ENV_FILE"

compose_cmd() {
  docker compose -p "$PROJECT_NAME" --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

cleanup_stale_recreate_containers() {
  docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" --format '{{.Names}}' |
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      case "$name" in
        *_"$PROJECT_NAME"-*)
          echo "CLEANUP stale recreate container=$name"
          docker rm -f "$name" >/dev/null 2>&1 || true
          ;;
      esac
    done
}

run_health_checks() {
  if [ -z "$HEALTH_URLS" ] && [ -z "$TCP_HEALTH_CHECKS" ]; then
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

    if [ "$passed" -eq 1 ] && [ -n "$TCP_HEALTH_CHECKS" ]; then
      if ! TCP_HEALTH_CHECKS="$TCP_HEALTH_CHECKS" python3 - <<'PY'
import os
import socket
import sys

checks = [line.strip() for line in os.environ.get("TCP_HEALTH_CHECKS", "").splitlines() if line.strip()]
for check in checks:
    if ":" not in check:
        print(f"invalid tcp health check target: {check}", file=sys.stderr)
        sys.exit(1)
    host, port_text = check.rsplit(":", 1)
    try:
        port = int(port_text)
    except ValueError:
        print(f"invalid tcp health check port: {check}", file=sys.stderr)
        sys.exit(1)
    try:
        with socket.create_connection((host, port), timeout=5):
            pass
    except OSError:
        sys.exit(1)
PY
      then
        passed=0
      fi
    fi

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
CURRENT_STEP="pull_images"
step_started_epoch="$(date +%s)"
compose_cmd pull $PULL_SERVICES
PULL_DURATION_SECONDS=$(( $(date +%s) - step_started_epoch ))
echo "MILESTONE pull completed duration_seconds=$PULL_DURATION_SECONDS"

CURRENT_STEP="restart_services"
step_started_epoch="$(date +%s)"
cleanup_stale_recreate_containers
compose_cmd up -d $UP_SERVICES
UP_DURATION_SECONDS=$(( $(date +%s) - step_started_epoch ))
echo "MILESTONE services restarted duration_seconds=$UP_DURATION_SECONDS"

if [ "$RUN_PRISMA" = "1" ]; then
  CURRENT_STEP="prisma_db_push"
  step_started_epoch="$(date +%s)"
  compose_cmd exec -T api npx prisma db push
  PRISMA_DURATION_SECONDS=$(( $(date +%s) - step_started_epoch ))
  echo "MILESTONE prisma db push completed duration_seconds=$PRISMA_DURATION_SECONDS"
fi

if [ "$SKIP_HEALTH" -eq 0 ]; then
  CURRENT_STEP="health_checks"
  step_started_epoch="$(date +%s)"
  run_health_checks
  HEALTH_DURATION_SECONDS=$(( $(date +%s) - step_started_epoch ))
else
  HEALTH_SKIPPED=1
  echo "MILESTONE health checks skipped"
fi

if [ -f "$CURRENT_RELEASE_FILE" ]; then
  cp "$CURRENT_RELEASE_FILE" "$PREVIOUS_RELEASE_FILE"
fi

DEPLOYED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SNAPSHOT_FILE="$RELEASE_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$IMAGE_TAG.json"
TOTAL_DURATION_SECONDS=$(( $(date +%s) - START_EPOCH ))
CURRENT_STEP="record_release"

python3 - "$CURRENT_RELEASE_FILE" "$SNAPSHOT_FILE" "$STARTED_AT" "$DEPLOYED_AT" "$SERVICE_ID" "$TARGET" "$IMAGE_TAG" "$IMAGE_SNAPSHOT_JSON" "$PLATFORM_COMMIT" "$PRODUCTION_REGISTRY" "$PULL_DURATION_SECONDS" "$UP_DURATION_SECONDS" "$PRISMA_DURATION_SECONDS" "$HEALTH_DURATION_SECONDS" "$TOTAL_DURATION_SECONDS" "$HEALTH_SKIPPED" <<'PY'
import json
import sys

current_path = sys.argv[1]
snapshot_path = sys.argv[2]
payload = {
    "startedAt": sys.argv[3],
    "deployedAt": sys.argv[4],
    "serviceId": sys.argv[5],
    "target": sys.argv[6],
    "imageTag": sys.argv[7],
    "images": json.loads(sys.argv[8]),
    "platformCommit": sys.argv[9],
    "productionRegistry": sys.argv[10],
    "durations": {
        "pullSeconds": int(sys.argv[11]),
        "upSeconds": int(sys.argv[12]),
        "prismaSeconds": int(sys.argv[13]),
        "healthSeconds": int(sys.argv[14]),
        "totalSeconds": int(sys.argv[15]),
    },
    "healthChecksSkipped": sys.argv[16] == "1",
}

for path in (current_path, snapshot_path):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=True, indent=2)
        fh.write("\n")
PY

CURRENT_STEP="completed"
ATTEMPT_NOTE="deploy completed"
echo "SUMMARY service_id=$SERVICE_ID target=$TARGET image_tag=$IMAGE_TAG platform_commit=$PLATFORM_COMMIT pull_duration_seconds=$PULL_DURATION_SECONDS up_duration_seconds=$UP_DURATION_SECONDS prisma_duration_seconds=$PRISMA_DURATION_SECONDS health_duration_seconds=$HEALTH_DURATION_SECONDS total_duration_seconds=$TOTAL_DURATION_SECONDS"
