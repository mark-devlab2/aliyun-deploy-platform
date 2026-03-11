#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: login-registries.sh <contract.json>" >&2
  exit 1
fi

CONTRACT_FILE="$1"
TMP_REGISTRY_MATRIX="$(mktemp)"

python3 - "$CONTRACT_FILE" <<'PY' >"$TMP_REGISTRY_MATRIX"
import json
import sys

doc = json.load(open(sys.argv[1], "r", encoding="utf-8"))
for name, config in doc.get("registries", {}).items():
    if config.get("enabled", True):
        print("\t".join([name, config["host"]]))
PY

while IFS="$(printf '\t')" read -r registry_name registry_host; do
  [ -n "$registry_name" ] || continue
  case "$registry_name:$registry_host" in
    ghcr:ghcr.io)
      if [ -z "${GHCR_PUSH_USERNAME:-}" ] || [ -z "${GHCR_PUSH_TOKEN:-}" ]; then
        echo "missing GHCR push credentials for ghcr.io login" >&2
        exit 1
      fi
      printf '%s' "$GHCR_PUSH_TOKEN" | docker login "$registry_host" -u "$GHCR_PUSH_USERNAME" --password-stdin >/dev/null
      ;;
    acr:*.aliyuncs.com|default:*.aliyuncs.com)
      if [ -z "${ACR_USERNAME:-}" ] || [ -z "${ACR_PASSWORD:-}" ]; then
        echo "missing ACR credentials for $registry_host login" >&2
        exit 1
      fi
      printf '%s' "$ACR_PASSWORD" | docker login "$registry_host" -u "$ACR_USERNAME" --password-stdin >/dev/null
      ;;
    *)
      echo "unsupported registry login target: $registry_name ($registry_host)" >&2
      exit 1
      ;;
  esac
done <"$TMP_REGISTRY_MATRIX"

rm -f "$TMP_REGISTRY_MATRIX"
