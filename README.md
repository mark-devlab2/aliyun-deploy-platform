# Aliyun Deploy Platform

统一承载所有部署到阿里云服务的发布标准。

## 职责边界

- 平台仓：
  - reusable workflows
  - 统一 deploy/rollback/bootstrap 脚本
  - 服务注册表
  - 生产 compose 模板
- 服务仓：
  - Dockerfile
  - 测试命令
  - `.deploy/build.yaml`
  - 薄调用 `release.yml`
- 服务器：
  - 平台仓
  - 运行时 env
  - release state
  - 镜像 pull 与容器重启

## 标准流程

1. 服务仓 `push main`
2. GitHub Actions 跑测试
3. GitHub Actions 构建镜像并推送到 GHCR
4. GitHub Actions 通过 SSH 触发服务器部署
5. 服务器 pull `sha-*` 镜像并重启容器
6. 服务器执行健康检查并记录回滚元数据

## 命名规范

- 镜像：`ghcr.io/mark-devlab2/<service-id>-<image-name>`
- 生产标签：`sha-<gitsha>`
- 滚动标签：`main`
- 不使用 `latest`

## 目录

- `.github/workflows/build-publish.yml`
- `.github/workflows/deploy-service.yml`
- `docs/first-release-checklist.md`
- `docs/service-onboarding.md`
- `scripts/bootstrap-server.sh`
- `scripts/deploy-service.sh`
- `scripts/rollback-service.sh`
- `services/<service-id>/deploy.yaml`
- `services/<service-id>/compose.prod.yml`
- `services/<service-id>/compose.prod.env.example`

## GitHub Secrets

服务仓至少需要：

- `ALIYUN_HOST`
- `ALIYUN_SSH_USER`
- `ALIYUN_SSH_PRIVATE_KEY`
- `GHCR_PULL_USERNAME`
- `GHCR_PULL_TOKEN`

可选：

- `ALIYUN_SSH_PORT`
- `ALIYUN_SSH_KNOWN_HOSTS`
- `PLATFORM_GIT_URL`
- `REMOTE_PLATFORM_DIR`
- `PLATFORM_REPO_TOKEN`

## 服务接入步骤

1. 服务仓新增 `.deploy/build.yaml`
2. 服务仓新增 `.github/workflows/release.yml`
3. 平台仓新增 `services/<service-id>/deploy.yaml`
4. 平台仓新增 `services/<service-id>/compose.prod.yml`
5. 服务器初始化平台仓并写入 `runtime/<service-id>/service.env`

## 首个样板

`feishu-token-service` 已作为首个样板接入，保留：

- `api`
- `admin-web`
- `full`

其中 `api/full` 会在部署后执行 `docker compose exec -T api npx prisma db push`。

## 文档

- 首次上线步骤见 `docs/first-release-checklist.md`
- 新服务接入模板见 `docs/service-onboarding.md`
