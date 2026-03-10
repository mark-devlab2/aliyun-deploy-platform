#!/usr/bin/env python3
import json
import sys
from pathlib import Path


def load_json_yaml(path_str: str) -> dict:
    path = Path(path_str)
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise SystemExit(f"config file not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise SystemExit(f"invalid JSON/YAML document in {path}: {exc}") from exc


def normalize_build_contract(doc: dict) -> dict:
    service_id = doc.get("serviceId", "").strip()
    registry = doc.get("registry", {})
    host = registry.get("host", "ghcr.io").strip()
    owner = registry.get("owner", "").strip()
    images = []

    if not service_id:
        raise SystemExit("build contract missing serviceId")
    if not owner:
        raise SystemExit("build contract missing registry.owner")

    for image in doc.get("images", []):
        name = image.get("name", "").strip()
        image_name = image.get("image", "").strip()
        context = image.get("context", "").strip()
        dockerfile = image.get("dockerfile", "").strip()
        if not name or not image_name or not context or not dockerfile:
            raise SystemExit(f"invalid image entry in build contract: {image}")
        images.append(
            {
                "name": name,
                "image": image_name,
                "context": context,
                "dockerfile": dockerfile,
                "repository": f"{host}/{owner}/{image_name}",
            }
        )

    return {
        "serviceId": service_id,
        "test": doc.get("test", {}),
        "deploy": doc.get("deploy", {}),
        "registry": {"host": host, "owner": owner},
        "images": images,
    }


def normalize_deploy_contract(doc: dict) -> dict:
    service_id = doc.get("serviceId", "").strip()
    project_name = doc.get("projectName", "").strip()
    compose_file = doc.get("composeFile", "").strip()
    runtime_dir = doc.get("runtimeDir", "").strip()
    images = doc.get("images", {})
    targets = doc.get("targets", {})
    if not service_id or not project_name or not compose_file or not runtime_dir:
        raise SystemExit("deploy contract missing required keys")
    if not images or not targets:
        raise SystemExit("deploy contract missing images or targets")
    return doc


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: render-config.py <build-contract|deploy-contract> <path>")

    mode = sys.argv[1]
    path = sys.argv[2]
    doc = load_json_yaml(path)
    if mode == "build-contract":
        normalized = normalize_build_contract(doc)
    elif mode == "deploy-contract":
        normalized = normalize_deploy_contract(doc)
    else:
        raise SystemExit(f"unknown mode: {mode}")
    print(json.dumps(normalized, ensure_ascii=True, separators=(",", ":")))


if __name__ == "__main__":
    main()
