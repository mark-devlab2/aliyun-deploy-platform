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
  - deploy attempt state
  - 镜像 pull 与容器重启

## 标准流程

1. 服务仓 `push main`
2. GitHub Actions 跑测试
3. GitHub Actions 构建镜像并推送到 ACR（默认）或可选兼容 GHCR
4. GitHub Actions 通过 SSH 触发服务器部署
5. 服务器 pull `sha-*` 镜像并重启容器
6. 服务器执行健康检查并记录回滚元数据
7. GitHub Actions 输出本次 deploy attempt 摘要

## 命名规范

- 镜像：`registry.cn-beijing.aliyuncs.com/mark-devlab2/<service-id>-<image-name>`
- 生产标签：`sha-<gitsha>`
- 滚动标签：`main`
- 不使用 `latest`

## 目录

- `.github/workflows/validate-service.yml`
- `.github/workflows/build-publish.yml`
- `.github/workflows/deploy-service.yml`
- `docs/first-release-checklist.md`
- `docs/service-onboarding.md`
- `scripts/bootstrap-server.sh`
- `scripts/deploy-service.sh`
- `scripts/init-aliyun-service.py`
- `scripts/rollback-service.sh`
- `services/<service-id>/deploy.yaml`
- `services/<service-id>/compose.prod.yml`
- `services/<service-id>/compose.prod.env.example`

## GitHub Secrets

服务仓至少需要：

- `ALIYUN_HOST`
- `ALIYUN_SSH_USER`
- `ALIYUN_SSH_PRIVATE_KEY`
- `ACR_USERNAME`
- `ACR_PASSWORD`

可选：

- `ALIYUN_SSH_PORT`
- `ALIYUN_SSH_KNOWN_HOSTS`
- `PLATFORM_GIT_URL`
- `REMOTE_PLATFORM_DIR`
- `GHCR_PULL_USERNAME`
- `GHCR_PULL_TOKEN`

## 统一入口

优先使用统一入口生成或接管服务：

```bash
python3 scripts/init-aliyun-service.py init \
  --service-id my-service \
  --service-repo-dir /path/to/my-service \
  --archetype node-api
```

如果是已有仓迁入标准：

```bash
python3 scripts/init-aliyun-service.py adopt \
  --service-id my-service \
  --service-repo-dir /path/to/my-service \
  --archetype node-api
```

默认会生成并引用平台稳定线 `v1`，而不是直接跟随平台仓 `main`。

默认规则：

- `init` 默认不覆盖已有文件
- `adopt` 默认只补缺失文件
- 只有显式 `--force` 才覆盖已有文件
- 默认新服务仓和平台仓公开，ops/config/runtime 仓保持私有
- 默认只启用 ACR；只有明确需要镜像对外分发或多云复用时才启用 GHCR

## 服务接入步骤

1. 运行 `scripts/init-aliyun-service.py init` 或 `adopt`
2. 复核生成的 `.deploy/build.yaml` 和平台服务目录
3. 补全业务专属 Dockerfile、测试命令和 `service.env`
4. 配置 GitHub deploy secrets 或 ACR 凭证
5. 合并后通过 `push main` 自动发布

平台仓公开后，服务器默认通过 `https://github.com/<owner>/<repo>.git` 拉取平台代码，不再要求为平台仓额外保留 GitHub SSH 读权限。

## 首个样板

`feishu-token-service` 已作为首个样板接入，保留：

- `api`
- `admin-web`
- `full`

其中 `api/full` 会在部署后执行 `docker compose exec -T api npx prisma db push`。

当前 `feishu-token-service` 为了兼容已上线的 GHCR 发布链路，仍保留 GHCR 生产配置；平台侧已经具备 ACR-first 能力，待配置 ACR 账号后可把 `productionRegistry` 切到 `acr`。

## 文档

- 首次上线步骤见 `docs/first-release-checklist.md`
- 新服务接入模板见 `docs/service-onboarding.md`
