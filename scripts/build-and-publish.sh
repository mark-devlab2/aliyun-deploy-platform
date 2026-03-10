#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: build-and-publish.sh <contract.json> <git-sha>" >&2
  exit 1
fi

CONTRACT_FILE="$1"
GIT_SHA="$2"
IMAGE_TAG="sha-$GIT_SHA"
TMP_BUILD_MATRIX="$(mktemp)"

python3 - "$CONTRACT_FILE" <<'PY' >"$TMP_BUILD_MATRIX"
import json
import sys

doc = json.load(open(sys.argv[1], "r", encoding="utf-8"))
for image in doc["images"]:
    print("\t".join([image["name"], image["repository"], image["context"], image["dockerfile"]]))
PY

while IFS="$(printf '\t')" read -r name repository context dockerfile; do
  echo "BUILD image=$name repository=$repository context=$context dockerfile=$dockerfile"
  docker buildx build \
    --file "$dockerfile" \
    --tag "$repository:$IMAGE_TAG" \
    --tag "$repository:main" \
    --push \
    "$context"
done <"$TMP_BUILD_MATRIX"

rm -f "$TMP_BUILD_MATRIX"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'image_tag=%s\n' "$IMAGE_TAG" >>"$GITHUB_OUTPUT"
fi
