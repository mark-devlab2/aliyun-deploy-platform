#!/usr/bin/env python3
import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: render-release-summary.py <attempt.json>", file=sys.stderr)
        return 1

    path = Path(sys.argv[1])
    if not path.is_file():
        print(f"attempt file not found: {path}", file=sys.stderr)
        return 1

    doc = json.loads(path.read_text(encoding="utf-8"))
    durations = doc.get("durations", {})

    print("## Deploy Attempt")
    print(f"- Status: `{doc.get('status', 'unknown')}`")
    print(f"- Service: `{doc.get('serviceId', 'unknown')}`")
    print(f"- Target: `{doc.get('target', 'unknown')}`")
    print(f"- Image tag: `{doc.get('imageTag', 'unknown')}`")
    print(f"- Platform commit: `{doc.get('platformCommit', 'unknown')}`")
    print(f"- Last step: `{doc.get('lastStep', 'unknown')}`")
    print(f"- Started at: `{doc.get('startedAt', 'unknown')}`")
    print(f"- Ended at: `{doc.get('endedAt', 'unknown')}`")
    print(f"- Pull seconds: `{durations.get('pullSeconds', 0)}`")
    print(f"- Up seconds: `{durations.get('upSeconds', 0)}`")
    print(f"- Prisma seconds: `{durations.get('prismaSeconds', 0)}`")
    print(f"- Health seconds: `{durations.get('healthSeconds', 0)}`")
    print(f"- Total seconds: `{durations.get('totalSeconds', 0)}`")
    print(f"- Health skipped: `{doc.get('healthChecksSkipped', False)}`")
    note = doc.get("note")
    if note:
        print(f"- Note: {note}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
