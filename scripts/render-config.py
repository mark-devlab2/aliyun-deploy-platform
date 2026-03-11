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


def normalize_registry_name(host: str) -> str:
    if host == "ghcr.io":
        return "ghcr"
    if host.endswith(".aliyuncs.com"):
        return "acr"
    return "default"


def normalize_registry_map(doc: dict) -> tuple[dict, str]:
    registries = {}

    if "registries" in doc:
        for name, config in doc.get("registries", {}).items():
            host = config.get("host", "").strip()
            namespace = config.get("namespace", config.get("owner", "")).strip()
            enabled = bool(config.get("enabled", True))
            if not host or not namespace:
                raise SystemExit(f"invalid registry entry: {name}")
            registries[name] = {
                "host": host,
                "namespace": namespace,
                "enabled": enabled,
            }
    else:
        registry = doc.get("registry", {})
        host = registry.get("host", "ghcr.io").strip()
        namespace = registry.get("namespace", registry.get("owner", "")).strip()
        if not namespace:
            raise SystemExit("build contract missing registry.owner or registry.namespace")
        default_name = normalize_registry_name(host)
        registries[default_name] = {
            "host": host,
            "namespace": namespace,
            "enabled": True,
        }

    enabled_names = [name for name, config in registries.items() if config["enabled"]]
    if not enabled_names:
        raise SystemExit("at least one registry must be enabled")

    production_registry = (
        doc.get("deploy", {}).get("productionRegistry", "").strip()
        or doc.get("productionRegistry", "").strip()
        or enabled_names[0]
    )
    if production_registry not in registries:
        raise SystemExit(f"production registry not declared: {production_registry}")

    return registries, production_registry


def normalize_build_contract(doc: dict) -> dict:
    service_id = doc.get("serviceId", "").strip()
    registries, production_registry = normalize_registry_map(doc)
    images = []

    if not service_id:
        raise SystemExit("build contract missing serviceId")

    for image in doc.get("images", []):
        name = image.get("name", "").strip()
        image_name = image.get("image", "").strip()
        context = image.get("context", "").strip()
        dockerfile = image.get("dockerfile", "").strip()
        if not name or not image_name or not context or not dockerfile:
            raise SystemExit(f"invalid image entry in build contract: {image}")
        repositories = {}
        for registry_name, config in registries.items():
            if not config["enabled"]:
                continue
            repositories[registry_name] = (
                f"{config['host']}/{config['namespace']}/{image_name}"
            )
        images.append(
            {
                "name": name,
                "image": image_name,
                "context": context,
                "dockerfile": dockerfile,
                "repositories": repositories,
            }
        )

    return {
        "serviceId": service_id,
        "test": doc.get("test", {}),
        "deploy": {
            **doc.get("deploy", {}),
            "productionRegistry": production_registry,
        },
        "registries": registries,
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

    normalized_images = {}
    for image_name, value in images.items():
        if isinstance(value, str):
            normalized_images[image_name] = {normalize_registry_name(value.split("/", 1)[0]): value}
            continue
        if isinstance(value, dict):
            normalized = {}
            for registry_name, repository in value.items():
                if not isinstance(repository, str) or not repository.strip():
                    raise SystemExit(f"invalid repository entry for image {image_name}: {value}")
                normalized[registry_name] = repository.strip()
            normalized_images[image_name] = normalized
            continue
        raise SystemExit(f"invalid image mapping for {image_name}: {value}")

    production_registry = doc.get("productionRegistry", "").strip()
    if not production_registry:
        first_image = next(iter(normalized_images.values()))
        production_registry = next(iter(first_image.keys()))

    for image_name, registry_map in normalized_images.items():
        if production_registry not in registry_map:
            raise SystemExit(
                f"production registry {production_registry} missing for image {image_name}"
            )

    return {
        **doc,
        "images": normalized_images,
        "productionRegistry": production_registry,
    }


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
