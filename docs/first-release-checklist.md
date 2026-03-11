# 首发执行清单

本文档用于把阿里云服务切换到“GitHub Actions + ACR + 服务器 pull 镜像”。

## 1. 建立平台仓

在本机执行：

```bash
cd /Users/mark/Documents/New\ project/aliyun-deploy-platform
git remote add origin git@github.com:mark-devlab2/aliyun-deploy-platform.git
git add .
git commit -m "Bootstrap unified Aliyun deploy platform"
git push -u origin main
```

如果仓库名不同，请同步修改：

- `feishu-token-service/.github/workflows/release.yml`
- `openclaw-main-config/scripts/deploy-feishu-token-service.sh`
- 服务仓和平台仓中的 `PLATFORM_GIT_URL` 默认值

## 2. 服务仓推送接入文件

在 `feishu-token-service` 仓库提交并推送：

- `.deploy/build.yaml`
- `.github/workflows/release.yml`
- `docs/deploy-aliyun.md`

## 3. 配置 GitHub Secrets

在 `feishu-token-service` 仓库配置：

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

建议：

- `PLATFORM_REPO_TOKEN` 只在平台仓仍是私有仓时提供，并至少给 `contents:read`
- `GHCR_PULL_TOKEN` 只在需要 GHCR 兼容镜像源时保留，并至少给 `packages:read`

## 4. 初始化服务器

阿里云服务器上需要具备：

- `git`
- `docker`
- `docker compose`
- `curl`
- 拉取平台仓的 GitHub 权限
- 拉取 ACR 包的权限

推荐平台目录：

```text
/opt/aliyun-deploy-platform
```

首次可用平台脚本引导：

```bash
cd /Users/mark/Documents/New\ project/aliyun-deploy-platform
./scripts/bootstrap-server.sh \
  --remote-host '<aliyun-host>' \
  --remote-user '<aliyun-user>' \
  --platform-dir '/opt/aliyun-deploy-platform' \
  --platform-git-url 'https://github.com/mark-devlab2/aliyun-deploy-platform.git' \
  --platform-ref 'v1' \
  --service-id 'feishu-token-service'
```

## 5. 写远端 service.env

把下面的模板复制到远端：

```text
/opt/aliyun-deploy-platform/runtime/feishu-token-service/service.env
```

模板来源：

```text
services/feishu-token-service/compose.prod.env.example
```

必须替换所有占位值。平台脚本会拒绝带有：

- `replace_with_`
- `cli_xxx`

的配置文件。

## 6. 清理旧源码部署目录

确认平台部署可用后，移除对旧目录的依赖：

```text
/root/services/feishu-token-service
```

不要在首发前先删；先让新链路跑通，再切换。

## 7. 执行首发

推荐方式：

1. 向 `main` push 一次可控变更
2. 观察 `Release To Aliyun` workflow
3. 确认镜像标签为 `sha-<gitsha>`
4. 确认镜像源为 ACR；如果当前仍处于 GHCR 兼容阶段，先不要删除 GHCR 相关 secrets

如需手动触发：

```bash
deploy-feishu-token-service.sh --target full --image-tag sha-<gitsha>
```

## 8. 首发后核验

至少核验：

- `https://token.himark.me/health`
- `https://admin.himark.me/login`
- `docker compose ps`
- `docker compose exec -T api npx prisma db push` 已执行
- Feishu personal auth
- drive root list
- docs/wiki/minutes/messages

## 9. 回滚

服务器上会保留：

- `runtime/feishu-token-service/releases/current.json`
- `runtime/feishu-token-service/releases/previous.json`
- `runtime/feishu-token-service/releases/last_attempt.json`
- `runtime/feishu-token-service/releases/attempts/*.json`

默认回滚到上一版：

```bash
/opt/aliyun-deploy-platform/scripts/rollback-service.sh \
  --service-id feishu-token-service
```
