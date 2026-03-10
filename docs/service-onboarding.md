# 服务接入指南

后续所有部署到阿里云的服务，都按这份模板接入。

## 1. 服务仓必须提供

- `.deploy/build.yaml`
- 可重复构建的 Dockerfile
- 可重复执行的测试命令
- `.github/workflows/release.yml`

`build.yaml` 至少要定义：

- `serviceId`
- `registry.host`
- `registry.owner`
- `test.run`
- `images[].name`
- `images[].image`
- `images[].context`
- `images[].dockerfile`
- `deploy.defaultTarget`

## 2. 平台仓必须提供

每个服务都要新增：

- `services/<service-id>/deploy.yaml`
- `services/<service-id>/compose.prod.yml`
- `services/<service-id>/compose.prod.env.example`

如果入口代理配置属于运行时配置，也放在平台仓，例如：

- `services/<service-id>/Caddyfile`

## 3. 部署目标约定

如果服务有分目标部署能力，统一在 `deploy.yaml` 声明：

- `pullServices`
- `upServices`
- `runPrisma`
- `healthChecks`

不要把这些规则散落到每个服务仓自己的脚本里。

## 4. 镜像命名约定

统一使用：

```text
ghcr.io/mark-devlab2/<service-id>-<image-name>
```

标签统一：

- `sha-<gitsha>`
- `main`

不要使用：

- `latest`
- 服务仓各自自定义的标签格式

## 5. 服务器约定

服务器只保留：

- 平台仓
- `runtime/<service-id>/service.env`
- `runtime/<service-id>/compose.env`
- `runtime/<service-id>/releases/*`
- Docker named volumes

服务器不要保留：

- 应用源码仓
- 远端构建脚本
- 每个服务自定义的 compose/build 目录

## 6. 服务接入检查项

接入一个新服务前，至少回答清楚：

- 是否需要多镜像发布
- 是否需要数据库迁移或 Prisma 同步
- 哪些目标需要连带重启代理容器
- 健康检查 URL 是什么
- 服务器上的持久化卷是否需要兼容旧名字

## 7. 样板参考

首个样板：

- `services/feishu-token-service/deploy.yaml`
- `services/feishu-token-service/compose.prod.yml`
- `feishu-token-service/.deploy/build.yaml`

优先复制样板，再做最小化改动，不要重新发明一套发布规则。
