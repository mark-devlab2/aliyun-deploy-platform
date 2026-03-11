#!/bin/sh
set -eu

REMOTE_HOST=""
REMOTE_USER="root"
REMOTE_PORT="${REMOTE_PORT:-22}"
REMOTE_PLATFORM_DIR="${REMOTE_PLATFORM_DIR:-/opt/aliyun-deploy-platform}"
PLATFORM_GIT_URL="${PLATFORM_GIT_URL:-git@github.com:mark-devlab2/aliyun-deploy-platform.git}"
PLATFORM_REF="${PLATFORM_REF:-v1}"
SERVICE_ID=""
SSH_CONFIG_FILE="${SSH_CONFIG_FILE:-}"

usage() {
  cat >&2 <<'EOF'
usage: bootstrap-server.sh --remote-host <host> [options]

options:
  --remote-host <host>
  --remote-user <user>
  --remote-port <port>
  --platform-dir <path>
  --platform-git-url <url>
  --platform-ref <ref>
  --service-id <id>
EOF
}

ssh_run() {
  if [ -n "$SSH_CONFIG_FILE" ] && [ -f "$SSH_CONFIG_FILE" ]; then
    ssh -F "$SSH_CONFIG_FILE" -p "$REMOTE_PORT" -o ConnectTimeout=10 "$@"
  else
    ssh -p "$REMOTE_PORT" -o ConnectTimeout=10 "$@"
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --remote-host)
      REMOTE_HOST="$2"
      shift 2
      ;;
    --remote-user)
      REMOTE_USER="$2"
      shift 2
      ;;
    --remote-port)
      REMOTE_PORT="$2"
      shift 2
      ;;
    --platform-dir)
      REMOTE_PLATFORM_DIR="$2"
      shift 2
      ;;
    --platform-git-url)
      PLATFORM_GIT_URL="$2"
      shift 2
      ;;
    --platform-ref)
      PLATFORM_REF="$2"
      shift 2
      ;;
    --service-id)
      SERVICE_ID="$2"
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

if [ -z "$REMOTE_HOST" ]; then
  usage
  exit 1
fi

GHCR_USERNAME_B64="$(printf '%s' "${GHCR_USERNAME:-}" | base64 | tr -d '\n')"
GHCR_TOKEN_B64="$(printf '%s' "${GHCR_TOKEN:-}" | base64 | tr -d '\n')"

ssh_run "$REMOTE_USER@$REMOTE_HOST" "bash -s -- '$REMOTE_PLATFORM_DIR' '$PLATFORM_GIT_URL' '$PLATFORM_REF' '$SERVICE_ID' '$GHCR_USERNAME_B64' '$GHCR_TOKEN_B64'" <<'REMOTE'
set -eu

PLATFORM_DIR="$1"
PLATFORM_GIT_URL="$2"
PLATFORM_REF="$3"
SERVICE_ID="$4"
GHCR_USERNAME_B64="$5"
GHCR_TOKEN_B64="$6"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

require_cmd git
require_cmd docker
require_cmd curl

if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose unavailable" >&2
  exit 1
fi

checkout_platform_ref() {
  repo_dir="$1"
  platform_ref="$2"

  if git -C "$repo_dir" ls-remote --exit-code --heads origin "$platform_ref" >/dev/null 2>&1; then
    git -C "$repo_dir" fetch origin "refs/heads/$platform_ref:refs/remotes/origin/$platform_ref"
    git -C "$repo_dir" checkout -B "$platform_ref" "refs/remotes/origin/$platform_ref"
    return 0
  fi

  if git -C "$repo_dir" ls-remote --exit-code --tags origin "refs/tags/$platform_ref" >/dev/null 2>&1; then
    git -C "$repo_dir" fetch origin "refs/tags/$platform_ref:refs/tags/$platform_ref"
    git -C "$repo_dir" checkout --detach "refs/tags/$platform_ref"
    return 0
  fi

  echo "platform ref not found on origin: $platform_ref" >&2
  exit 1
}

platform_parent="$(dirname "$PLATFORM_DIR")"
mkdir -p "$platform_parent"

if [ ! -d "$PLATFORM_DIR/.git" ]; then
  git clone "$PLATFORM_GIT_URL" "$PLATFORM_DIR"
  checkout_platform_ref "$PLATFORM_DIR" "$PLATFORM_REF"
else
  git -C "$PLATFORM_DIR" remote set-url origin "$PLATFORM_GIT_URL"
  checkout_platform_ref "$PLATFORM_DIR" "$PLATFORM_REF"
fi

if [ -n "$GHCR_USERNAME_B64" ] && [ -n "$GHCR_TOKEN_B64" ]; then
  ghcr_username="$(printf '%s' "$GHCR_USERNAME_B64" | base64 -d)"
  ghcr_token="$(printf '%s' "$GHCR_TOKEN_B64" | base64 -d)"
  if [ -n "$ghcr_username" ] && [ -n "$ghcr_token" ]; then
    printf '%s' "$ghcr_token" | docker login ghcr.io -u "$ghcr_username" --password-stdin >/dev/null
  fi
fi

if [ -n "$SERVICE_ID" ]; then
  runtime_dir="$PLATFORM_DIR/runtime/$SERVICE_ID"
  release_dir="$runtime_dir/releases"
  example_env="$PLATFORM_DIR/services/$SERVICE_ID/compose.prod.env.example"
  service_env="$runtime_dir/service.env"

  mkdir -p "$release_dir"
  if [ ! -f "$service_env" ] && [ -f "$example_env" ]; then
    cp "$example_env" "$service_env"
  fi
fi

echo "BOOTSTRAP platform_dir=$PLATFORM_DIR ref=$PLATFORM_REF service_id=${SERVICE_ID:-none}"
REMOTE
