#!/bin/sh
set -eu

PLATFORM_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SERVICE_ID=""
TARGET=""
IMAGE_TAG=""

usage() {
  cat >&2 <<'EOF'
usage: rollback-service.sh --service-id <id> [options]

options:
  --platform-dir <path>
  --service-id <id>
  --target <api|admin-web|full>
  --image-tag <sha-...>
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

if [ -z "$SERVICE_ID" ]; then
  usage
  exit 1
fi

PREVIOUS_RELEASE_FILE="$PLATFORM_DIR/runtime/$SERVICE_ID/releases/previous.json"
if [ -z "$IMAGE_TAG" ]; then
  if [ ! -f "$PREVIOUS_RELEASE_FILE" ]; then
    echo "previous release file missing: $PREVIOUS_RELEASE_FILE" >&2
    exit 1
  fi
  IMAGE_TAG="$(python3 - "$PREVIOUS_RELEASE_FILE" <<'PY'
import json
import sys

doc = json.load(open(sys.argv[1], "r", encoding="utf-8"))
print(doc["imageTag"])
PY
)"
fi

if [ -z "$TARGET" ] && [ -f "$PREVIOUS_RELEASE_FILE" ]; then
  TARGET="$(python3 - "$PREVIOUS_RELEASE_FILE" <<'PY'
import json
import sys

doc = json.load(open(sys.argv[1], "r", encoding="utf-8"))
print(doc.get("target", "full"))
PY
)"
fi

if [ -z "$TARGET" ]; then
  TARGET="full"
fi

exec "$PLATFORM_DIR/scripts/deploy-service.sh" --platform-dir "$PLATFORM_DIR" --service-id "$SERVICE_ID" --target "$TARGET" --image-tag "$IMAGE_TAG"
