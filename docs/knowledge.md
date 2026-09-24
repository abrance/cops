# 仓库知识：容器镜像源约定

本文记录 `cops` 仓库的容器镜像源、配置位置和变更规则，作为新增服务与排障时的统一参考。

## 1. 统一镜像源

本仓库的 Compose 容器镜像统一使用：

```text
ghcr.chenby.cn/<组织>/<镜像>:<版本 tag>
```

例外只有两类，都必须在 `.env` 注释里说明理由：

- 上游官方镜像直接引用其原始源（如 `environment/ptdoc-qdrant` 的 `docker.io/qdrant/qdrant`，云主机已配 Docker Hub 内网 mirror）。
- tag 形状以上游实际发布为准：上游可能不带 `v` 前缀（如 ptdoc 网关的 `1.0.6`），不要为了统一而改写成仓库里不存在的 tag。

当前镜像地址由各部署单元目录下的 `.env` 文件直接声明，Compose 文件只负责把镜像名和版本 tag 拼接成最终引用。不要只修改文档示例而遗漏 `.env` 中的实际部署值。

## 2. 当前镜像清单

| 单元 | Compose 服务 | `.env` 变量 | 当前完整镜像 |
| --- | --- | --- | --- |
| `apps/lems` | `lems` | `LEMS_IMAGE` + `LEMS_IMAGE_TAG` | `ghcr.chenby.cn/abrance/ems:v1.0.8` |
| `apps/lems` | `emsdevice` | `EMSDEVICE_IMAGE` + `EMSDEVICE_IMAGE_TAG` | `ghcr.chenby.cn/abrance/emsdevice:v1.0.5` |
| `apps/ptdoc` | `ptdoc` | `PTDOC_IMAGE` + `PTDOC_IMAGE_TAG` | `ghcr.chenby.cn/abrance/ptdoc:v1.0.11` |
| `environment/ptdoc-qdrant` | `qdrant` | `QDRANT_IMAGE` + `QDRANT_IMAGE_TAG` | `docker.io/qdrant/qdrant:v1.19.1` |
| `environment/ptdoc-qdrant` | `gateway` | `GATEWAY_IMAGE` + `GATEWAY_IMAGE_TAG` | `ghcr.chenby.cn/abrance/ptdoc-qdrant-gateway:1.0.7` |
| `apps/model-logcluster` | `model-logcluster` | `MODEL_LOGCLUSTER_IMAGE` + `MODEL_LOGCLUSTER_IMAGE_TAG` | `ghcr.chenby.cn/abrance/modelman-logcluster:<tag>` |

配置来源：

- `apps/lems/.env`、`apps/lems/compose.yaml`
- `apps/ptdoc/.env`、`apps/ptdoc/compose.yaml`
- `apps/model-logcluster/.env`、`apps/model-logcluster/compose.yaml`
- `environment/ptdoc-qdrant/.env`、`environment/ptdoc-qdrant/compose.yaml`

部署脚本执行 `docker compose pull`，因此最终使用的镜像以 Compose 渲染结果为准。

## 3. 变更规则

- `*_IMAGE` 保存完整的镜像仓库地址，必须包含 `ghcr.chenby.cn`、组织名和镜像名。
- `*_IMAGE_TAG` 使用具体版本，例如 `v1.0.8`；不要使用 `latest`。上游 tag 不带 `v` 时按其实际形状写（如 `1.0.6`）。
- 保持 Compose 中 `${*_IMAGE}:${*_IMAGE_TAG}` 的现有写法，不要额外引入一个未被 Compose 使用的全局 `REGISTRY` 变量。
- 镜像、tag 和 Compose 配置的变更都要提交到仓库并通过分支 + PR 合入 `main`。
- 不要把 registry 用户名、密码、token 或其他敏感信息写入 `.env`、Compose 文件或文档。当前仓库没有在 GitHub Actions 中保存或注入 registry 登录凭据。
- 不要随意混用其他 registry 或未登记的代理地址；如果镜像源需要调整，应同时更新实际配置、接入模板、排障说明和本文档。
- 云主机上 `ghcr.io` 直连回源 GitHub CDN 极慢，会卡在 `Pulling fs layer`；引用 GHCR 镜像时写 `ghcr.chenby.cn` 路径。

## 4. 校验方式

本地修改后，使用与 CI 相同的 Compose 配置校验：

```bash
docker compose \
  --project-directory apps/lems \
  -f apps/lems/compose.yaml \
  config --quiet

docker compose \
  --project-directory apps/ptdoc \
  -f apps/ptdoc/compose.yaml \
  config --quiet

docker compose \
  --project-directory environment/ptdoc-qdrant \
  -f environment/ptdoc-qdrant/compose.yaml \
  config --quiet
```

再查看最终展开的镜像名：

```bash
docker compose \
  --project-directory apps/lems \
  -f apps/lems/compose.yaml \
  config --images

docker compose \
  --project-directory apps/ptdoc \
  -f apps/ptdoc/compose.yaml \
  config --images
```

`config --quiet` 和 `config --images` 只校验本地编排与变量展开，不保证远端 tag 已存在。真正的镜像拉取发生在部署阶段；排障时可在目标主机使用完整镜像名执行 `docker pull` 验证。

## 5. 运行期覆盖与排除项

Compose 的 shell 环境变量优先级高于项目 `.env`，部署脚本还可能加载 `/opt/cops/secrets/<app>.env`。如果服务器侧提供了同名变量，实际部署值可能与仓库文件不同，应以 `docker compose config --images` 的最终结果为准。

本约定只适用于 `compose` 部署的 Docker 镜像。`apps/vectorman/` 使用 `DEPLOY_MODE=native`，部署的是 GitHub Releases 发布包和 systemd 服务，不要把它的 `NATIVE_ARTIFACT_URL` 或 `NATIVE_ARTIFACT_SHA256` 当作容器镜像字段修改。
