#!/usr/bin/env python3
import argparse
import json
import re
from pathlib import Path
from textwrap import dedent


PLATFORM_ROOT = Path(__file__).resolve().parent.parent


def normalize_env_name(name: str) -> str:
    return re.sub(r"[^A-Z0-9]+", "_", name.upper()) + "_IMAGE"


def service_slug(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", value.lower()).strip("_")


def image_repository(registry_host: str, registry_owner: str, service_id: str, image_name: str) -> str:
    return f"{registry_host}/{registry_owner}/{service_id}-{image_name}"


def build_contract(args) -> dict:
    images = [
        {
            "name": "api",
            "image": f"{args.service_id}-api",
            "context": args.api_context,
            "dockerfile": args.api_dockerfile,
        }
    ]
    default_target = "api"

    if args.archetype == "node-api-admin-web":
        images.append(
            {
                "name": "admin-web",
                "image": f"{args.service_id}-admin-web",
                "context": args.admin_context,
                "dockerfile": args.admin_dockerfile,
            }
        )
        default_target = "full"

    return {
        "serviceId": args.service_id,
        "registry": {
            "host": args.registry_host,
            "owner": args.registry_owner,
        },
        "runtime": {
            "type": args.runtime_type,
            "version": args.runtime_version,
        },
        "test": {"run": args.test_command},
        "images": images,
        "deploy": {"defaultTarget": args.default_target or default_target},
    }


def deploy_contract(args) -> dict:
    images = {
        "api": image_repository(args.registry_host, args.registry_owner, args.service_id, "api")
    }
    targets = {
        "api": {
            "pullServices": ["api"],
            "upServices": ["api"],
            "runPrisma": args.run_prisma,
            "healthChecks": [args.api_health_url],
        }
    }

    if args.archetype == "node-api-admin-web":
        images["admin-web"] = image_repository(
            args.registry_host, args.registry_owner, args.service_id, "admin-web"
        )
        targets["admin-web"] = {
            "pullServices": ["admin-web"],
            "upServices": ["admin-web", "caddy"],
            "runPrisma": False,
            "healthChecks": [args.admin_health_url],
        }
        targets["full"] = {
            "pullServices": ["api", "admin-web"],
            "upServices": ["api", "admin-web", "caddy"],
            "runPrisma": args.run_prisma,
            "healthChecks": [args.api_health_url, args.admin_health_url],
        }

    return {
        "serviceId": args.service_id,
        "projectName": args.project_name,
        "composeFile": f"services/{args.service_id}/compose.prod.yml",
        "runtimeDir": args.runtime_dir,
        "images": images,
        "targets": targets,
    }


def render_compose(args) -> str:
    lines = [
        "services:",
        "  api:",
        '    image: "${API_IMAGE}"',
        "    ports:",
        '      - "${API_PUBLISH}"',
        "    env_file:",
        f"      - ../../runtime/{args.service_id}/service.env",
    ]

    api_depends = []
    if args.with_postgres:
        api_depends.extend(
            [
                "      postgres:",
                "        condition: service_healthy",
            ]
        )
    if args.with_redis:
        api_depends.extend(
            [
                "      redis:",
                "        condition: service_started",
            ]
        )
    if api_depends:
        lines.append("    depends_on:")
        lines.extend(api_depends)

    if args.archetype == "node-api-admin-web":
        lines.extend(
            [
                "",
                "  admin-web:",
                '    image: "${ADMIN_WEB_IMAGE}"',
                "    depends_on:",
                "      api:",
                "        condition: service_started",
                "",
                "  caddy:",
                "    image: caddy:2",
                "    ports:",
                '      - "${CADDY_HTTP_PUBLISH:-80:80}"',
                '      - "${CADDY_HTTPS_PUBLISH:-443:443}"',
                "    volumes:",
                "      - ./Caddyfile:/etc/caddy/Caddyfile:ro",
                "      - caddy_data:/data",
                "      - caddy_config:/config",
                "    depends_on:",
                "      api:",
                "        condition: service_started",
                "      admin-web:",
                "        condition: service_started",
            ]
        )

    if args.with_postgres:
        db_name = service_slug(args.service_id)
        lines.extend(
            [
                "",
                "  postgres:",
                "    image: postgres:16",
                "    environment:",
                f'      POSTGRES_DB: "${{POSTGRES_DB:-{db_name}}}"',
                '      POSTGRES_USER: "${POSTGRES_USER:-postgres}"',
                '      POSTGRES_PASSWORD: "${POSTGRES_PASSWORD:-postgres}"',
                "    ports:",
                '      - "${POSTGRES_PUBLISH:-5433:5432}"',
                "    healthcheck:",
                f'      test: ["CMD-SHELL", "pg_isready -U ${{POSTGRES_USER:-postgres}} -d ${{POSTGRES_DB:-{db_name}}}"]',
                "      interval: 10s",
                "      timeout: 5s",
                "      retries: 5",
                "    volumes:",
                "      - postgres_data:/var/lib/postgresql/data",
            ]
        )

    if args.with_redis:
        lines.extend(
            [
                "",
                "  redis:",
                "    image: redis:7",
                "    ports:",
                '      - "${REDIS_PUBLISH:-6380:6379}"',
                '    command: ["redis-server", "--appendonly", "yes"]',
                "    volumes:",
                "      - redis_data:/data",
            ]
        )

    lines.extend(["", "volumes:"])
    if args.with_postgres:
        lines.append("  postgres_data:")
    if args.with_redis:
        lines.append("  redis_data:")
    if args.archetype == "node-api-admin-web":
        lines.append("  caddy_data:")
        lines.append("  caddy_config:")

    return "\n".join(lines) + "\n"


def render_env_example(args) -> str:
    db_name = service_slug(args.service_id)
    lines = [
        "NODE_ENV=production",
        "PORT=3000",
        f"API_PUBLISH={args.api_publish}",
    ]

    if args.archetype == "node-api-admin-web":
        lines.extend(
            [
                f"CADDY_HTTP_PUBLISH={args.caddy_http_publish}",
                f"CADDY_HTTPS_PUBLISH={args.caddy_https_publish}",
                f"APP_BASE_URL=https://{args.api_host}",
                f"ADMIN_BASE_URL=https://{args.admin_host}",
            ]
        )

    if args.with_postgres:
        lines.extend(
            [
                f"POSTGRES_PUBLISH={args.postgres_publish}",
                f"POSTGRES_DB={db_name}",
                "POSTGRES_USER=postgres",
                "POSTGRES_PASSWORD=postgres",
                f"DATABASE_URL=postgresql://postgres:postgres@postgres:5432/{db_name}?schema=public",
            ]
        )

    if args.with_redis:
        lines.extend(
            [
                f"REDIS_PUBLISH={args.redis_publish}",
                "REDIS_URL=redis://redis:6379",
            ]
        )

    lines.extend(
        [
            "",
            "# Add application-specific variables below.",
            "APP_SECRET=replace_with_application_secret",
        ]
    )

    if args.archetype == "node-api-admin-web":
        lines.extend(
            [
                "ADMIN_USERNAME=admin",
                "ADMIN_PASSWORD=replace_with_admin_password",
                "ADMIN_WEB_ORIGINS=https://replace_with_admin_origin",
            ]
        )

    return "\n".join(lines) + "\n"


def render_caddyfile(args) -> str:
    return dedent(
        f"""\
        {args.api_host} {{
          encode gzip zstd
          reverse_proxy api:3000
        }}

        {args.admin_host} {{
          encode gzip zstd

          @adminApi path /admin-api/*
          reverse_proxy @adminApi api:3000

          reverse_proxy admin-web:80
        }}
        """
    )


def render_release_workflow(args) -> str:
    return dedent(
        f"""\
        name: Release To Aliyun

        on:
          push:
            branches:
              - main

        permissions:
          contents: read
          packages: write

        jobs:
          build_publish:
            uses: {args.platform_repo}/.github/workflows/build-publish.yml@{args.platform_ref}
            with:
              build_config_path: .deploy/build.yaml
              platform_repo: {args.platform_repo}
              platform_ref: {args.platform_ref}
            secrets: inherit

          deploy:
            needs: build_publish
            uses: {args.platform_repo}/.github/workflows/deploy-service.yml@{args.platform_ref}
            with:
              service_id: ${{{{ needs.build_publish.outputs.service_id }}}}
              image_tag: ${{{{ needs.build_publish.outputs.image_tag }}}}
              target: ${{{{ needs.build_publish.outputs.deploy_target }}}}
              platform_repo: {args.platform_repo}
              platform_ref: {args.platform_ref}
            secrets: inherit
        """
    )


def render_validate_workflow(args) -> str:
    return dedent(
        f"""\
        name: Validate Aliyun Release Contract

        on:
          pull_request:
          workflow_dispatch:

        permissions:
          contents: read

        jobs:
          validate:
            uses: {args.platform_repo}/.github/workflows/validate-service.yml@{args.platform_ref}
            with:
              build_config_path: .deploy/build.yaml
              platform_repo: {args.platform_repo}
              platform_ref: {args.platform_ref}
            secrets: inherit
        """
    )


def render_service_doc(args) -> str:
    lines = [
        f"# {args.service_id} 阿里云发布说明",
        "",
        "本服务接入统一阿里云发布平台，生产主路径固定为：",
        "",
        "1. Pull Request 跑 `validate.yml`",
        "2. `push main` 触发 GitHub Actions",
        "3. GitHub Actions 跑测试、构建镜像并推送 GHCR",
        "4. GitHub Actions 触发阿里云服务器 pull 镜像并重启",
        "5. 服务器执行健康检查并记录回滚状态",
        "",
        "## 服务仓必备文件",
        "",
        "- `.deploy/build.yaml`",
        "- `.github/workflows/validate.yml`",
        "- `.github/workflows/release.yml`",
        "",
        "## 平台仓对应文件",
        "",
        f"- `services/{args.service_id}/deploy.yaml`",
        f"- `services/{args.service_id}/compose.prod.yml`",
        f"- `services/{args.service_id}/compose.prod.env.example`",
    ]
    if args.archetype == "node-api-admin-web":
        lines.append(f"- `services/{args.service_id}/Caddyfile`")

    lines.extend(
        [
            "",
            "## 服务器运行目录",
            "",
            f"- `/opt/aliyun-deploy-platform/runtime/{args.service_id}/service.env`",
            "",
            "## 首发前必须完成",
            "",
            "- 填好 GitHub deploy secrets",
            "- 补全 `service.env` 中的业务环境变量",
            "- 校验健康检查 URL 和域名配置",
            "",
            "## 参考",
            "",
            f"- 平台仓：`{args.platform_repo}`",
            "- 平台接入指南：`aliyun-deploy-platform/docs/service-onboarding.md`",
        ]
    )
    return "\n".join(lines) + "\n"


def generated_files(args):
    service_repo = args.service_repo_dir.resolve()
    platform_service_dir = args.platform_dir.resolve() / "services" / args.service_id
    files = {
        service_repo / ".deploy" / "build.yaml": json.dumps(build_contract(args), ensure_ascii=True, indent=2) + "\n",
        service_repo / ".github" / "workflows" / "validate.yml": render_validate_workflow(args),
        service_repo / ".github" / "workflows" / "release.yml": render_release_workflow(args),
        service_repo / "docs" / "deploy-aliyun.md": render_service_doc(args),
        platform_service_dir / "deploy.yaml": json.dumps(deploy_contract(args), ensure_ascii=True, indent=2) + "\n",
        platform_service_dir / "compose.prod.yml": render_compose(args),
        platform_service_dir / "compose.prod.env.example": render_env_example(args),
    }
    if args.archetype == "node-api-admin-web":
        files[platform_service_dir / "Caddyfile"] = render_caddyfile(args)
    return files


def write_generated_file(path: Path, content: str, mode: str, force: bool) -> str:
    if path.exists():
        if mode == "adopt" and not force:
            return "skipped"
        if mode == "init" and not force:
            raise SystemExit(f"refusing to overwrite existing file: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    action = "updated" if path.exists() else "created"
    path.write_text(content, encoding="utf-8")
    return action


def parse_args():
    parser = argparse.ArgumentParser(description="Initialize or adopt an Aliyun service into the deploy platform.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    def add_common_flags(subparser):
        subparser.add_argument("--service-id", required=True)
        subparser.add_argument("--service-repo-dir", type=Path, required=True)
        subparser.add_argument("--platform-dir", type=Path, default=PLATFORM_ROOT)
        subparser.add_argument("--archetype", choices=["node-api", "node-api-admin-web"], default="node-api")
        subparser.add_argument("--registry-host", default="ghcr.io")
        subparser.add_argument("--registry-owner", default="mark-devlab2")
        subparser.add_argument("--platform-repo", default="mark-devlab2/aliyun-deploy-platform")
        subparser.add_argument("--platform-ref", default="main")
        subparser.add_argument("--runtime-type", default="node")
        subparser.add_argument("--runtime-version", default="22")
        subparser.add_argument("--test-command", default="npm test")
        subparser.add_argument("--api-context", default=".")
        subparser.add_argument("--api-dockerfile", default="Dockerfile")
        subparser.add_argument("--admin-context", default=".")
        subparser.add_argument("--admin-dockerfile", default="apps/admin-web.Dockerfile")
        subparser.add_argument("--project-name", default="")
        subparser.add_argument("--runtime-dir", default="")
        subparser.add_argument("--default-target", default="")
        subparser.add_argument("--api-host", default="")
        subparser.add_argument("--admin-host", default="")
        subparser.add_argument("--api-health-url", default="")
        subparser.add_argument("--admin-health-url", default="")
        subparser.add_argument("--api-publish", default="127.0.0.1:3000:3000")
        subparser.add_argument("--caddy-http-publish", default="80:80")
        subparser.add_argument("--caddy-https-publish", default="443:443")
        subparser.add_argument("--postgres-publish", default="5433:5432")
        subparser.add_argument("--redis-publish", default="6380:6379")
        subparser.add_argument("--run-prisma", action=argparse.BooleanOptionalAction, default=False)
        subparser.add_argument("--with-postgres", action=argparse.BooleanOptionalAction, default=True)
        subparser.add_argument("--with-redis", action=argparse.BooleanOptionalAction, default=True)
        subparser.add_argument("--force", action="store_true")

    add_common_flags(subparsers.add_parser("init"))
    add_common_flags(subparsers.add_parser("adopt"))
    return parser.parse_args()


def fill_defaults(args):
    if not args.project_name:
        args.project_name = args.service_id
    if not args.runtime_dir:
        args.runtime_dir = f"runtime/{args.service_id}"
    if not args.api_host:
        args.api_host = f"{args.service_id}.example.com"
    if args.archetype == "node-api-admin-web" and not args.admin_host:
        args.admin_host = f"admin.{args.service_id}.example.com"
    if not args.api_health_url:
        args.api_health_url = f"https://{args.api_host}/health"
    if args.archetype == "node-api-admin-web" and not args.admin_health_url:
        args.admin_health_url = f"https://{args.admin_host}/login"
    return args


def main():
    args = fill_defaults(parse_args())

    if args.command == "adopt" and not args.service_repo_dir.exists():
        raise SystemExit(f"service repository directory not found: {args.service_repo_dir}")

    writes = generated_files(args)
    created = []
    updated = []
    skipped = []

    for path, content in writes.items():
        action = write_generated_file(path, content, args.command, args.force)
        if action == "created":
            created.append(path)
        elif action == "updated":
            updated.append(path)
        else:
            skipped.append(path)

    summary = {
        "command": args.command,
        "serviceId": args.service_id,
        "archetype": args.archetype,
        "serviceRepoDir": str(args.service_repo_dir.resolve()),
        "platformDir": str(args.platform_dir.resolve()),
        "created": [str(path) for path in created],
        "updated": [str(path) for path in updated],
        "skipped": [str(path) for path in skipped],
        "nextSteps": [
            "Fill service.env with real application settings.",
            "Configure GitHub deploy secrets in the service repo.",
            "Review generated health URLs, domains, Dockerfiles, and compose defaults.",
        ],
    }
    print(json.dumps(summary, ensure_ascii=True, indent=2))


if __name__ == "__main__":
    main()
