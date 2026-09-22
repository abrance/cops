# cops

云主机服务的 GitOps CD 仓库。本仓库是部署期望状态的唯一事实源：修改 `apps/<app>/`（应用）或 `environment/<name>/`（应用依赖的环境组件）下的文件并合入 `main`，GitHub Actions 会把该单元同步到云主机并应用。

## 架构

```text
开发者 / PR ──► cops(main) ──► GitHub Actions ──SSH──► 云主机
                                 │                     ├─ 同步 /opt/cops/apps/<app>
                                 │                     ├─ 同步 /opt/cops/environment/<name>
                                 │                     ├─ docker compose pull
                                 │                     └─ up -d + 健康检查
                                 └─ 凭据来自 GitHub Secrets
```

- 目录约定：`apps/<名字>/` 是应用；`environment/<名字>/` 是**应用所依赖的环境组件**（中间件等），两者内容布局完全一致（`compose.yaml` + `.env` + `app.conf`），只是同步到云主机的根目录不同（`/opt/cops/apps/<名字>` 与 `/opt/cops/environment/<名字>`）。
- 触发方式：PR 只做编排校验不部署；合入 `main` 后只部署受影响单元；`workflow_dispatch` 可手动指定或全量；每天定时全量重建以纠正漂移。
- 镜像来源：应用镜像由各自源码仓库构建并发布，Compose 部署统一从 `ghcr.chenby.cn` 拉取；本仓库不保存 registry 凭据。
- 密钥分层：SSH 主机 / 账号 / 密码放 GitHub Secrets；运行期密钥放云主机 `/opt/cops/secrets/<名字>.env`（权限 600，不入库）。
- 部署模式：默认 `compose`（容器编排）；`app.conf` 声明 `DEPLOY_MODE=native` 的单元走发布包 + systemd 部署，见下文「native 部署模式」。

## 已纳管应用

| 应用 | 容器 | 镜像 | 说明 |
| --- | --- | --- | --- |
| `lems` | `lems`、`emsdevice` | `ghcr.chenby.cn/abrance/ems`、`ghcr.chenby.cn/abrance/emsdevice` | EMS 主服务与 ess_demo Modbus 从站 |
| `ptdoc` | `ptdoc` | `ghcr.chenby.cn/abrance/ptdoc` | Markdown 文档站；数据保留在 `/opt/ptdoc` |
| `vectorman` | 无（systemd） | GitHub Releases 静态二进制包 | GSE 采集链路的 6 个组件，native 部署，数据保留在 `/opt/vectorman` |
| `model-ocr` | `model-ocr` | `ghcr.chenby.cn/abrance/modelman-ocr` | PP-OCR 文字识别服务，只监听 `127.0.0.1:9101`；源码仓库 [abrance/modelman](https://github.com/abrance/modelman) |

## 已纳管环境组件

| 组件 | 容器 | 镜像 | 说明 |
| --- | --- | --- | --- |
| `ptdoc-qdrant` | `ptdoc-qdrant`、`ptdoc-qdrant-gateway` | `docker.io/qdrant/qdrant`、`ghcr.chenby.cn/abrance/ptdoc-qdrant-gateway` | ptdoc 的知识库：Qdrant 向量库 + 本地向量化网关；数据保留在 `/opt/ptdoc-qdrant`；`apps/ptdoc` 依赖它 |

环境组件的规则与 apps 一致，额外几条：

- 名字在 `apps/` 与 `environment/` 之间必须唯一（密钥文件与容器名都按名字定位）。
- 环境组件**不要反向依赖任何 apps 单元**：网络、卷都用自己项目的默认对象，不引用 `external` 的 apps 网络。
- 宿主机的公网入口（TLS、域名反代，如 `qdrantgw.xiaoyxq.top` → `127.0.0.1:6335`）由 dockpanel/traefik 管理，不在本仓库范围；仓库只保证服务的回环监听端口。
- 同一次全量部署**不保证 environment 先于 apps 执行**。依赖关系靠各自的健康检查与重试兜住；主机重建后建议先手动触发环境组件，再触发应用。

## 目录结构

```text
.
├── apps/                  # 应用（一个目录 = 一个 compose 项目）
│   ├── lems/
│   │   ├── app.conf       # 应用元数据：健康检查容器 / 超时 / 探测地址 / 必需变量
│   │   ├── compose.yaml   # 期望状态编排
│   │   ├── .env           # 非敏感变量（随仓库提交）
│   │   └── emsdevice.json # 服务配置文件
│   └── ptdoc/
│       ├── app.conf
│       ├── compose.yaml
│       └── .env
├── environment/           # 应用依赖的环境组件（布局与 apps 相同）
│   └── ptdoc-qdrant/
│       ├── app.conf
│       ├── compose.yaml
│       └── .env
├── scripts/
│   └── deploy.sh          # 在云主机上执行的部署脚本
└── .github/workflows/
    └── deploy.yml         # 解析变更 → 校验 → 部署
```

## GitHub Secrets

在 `Settings → Secrets and variables → Actions` 配置：

| 名称 | 必填 | 说明 |
| --- | --- | --- |
| `DEPLOY_HOST` | 是 | 云主机地址 |
| `DEPLOY_USER` | 是 | SSH 用户 |
| `DEPLOY_PASSWORD` | 是 | SSH 密码 |
| `DEPLOY_PORT` | 否 | SSH 端口，默认 `22` |
| `DEPLOY_KNOWN_HOSTS` | 否 | 服务器 SSH 主机公钥，建议固定（不配置时用 `ssh-keyscan` 临时获取） |
| `PTDOC_DATA_KEY` | 是 | `ptdoc` 运行期密钥，用于加解密七牛 SecretKey；部署时下发到 `/opt/cops/secrets/ptdoc.env` |

应用运行期密钥统一放 GitHub Secrets，由 CI 在部署前写入云主机的 `/opt/cops/secrets/<app>.env`（权限 600，不入库）。密钥通过 stdin 传输，不经过命令行，也不会落盘到 runner。

## 部署流程

1. 修改 `apps/<app>/`（应用）或 `environment/<name>/`（环境组件）下的期望状态并提交到 `main`。
2. 开 PR 后 Actions 先做编排校验，不触碰云主机；合入 `main` 后进入部署。
3. Actions 计算受影响单元列表（`<scope>/<名字>`），对每个单元执行：
   - `docker compose config` 校验编排文件
   - 通过 SSH 将目录同步到 `/opt/cops/<scope>/<名字>/`
   - 在服务器上执行 `scripts/deploy.sh <名字> <scope>`：拉取镜像 → `up -d` → 等待容器健康 → 探测健康接口
4. 部署失败时 job 非零退出，容器日志会打印到 Actions 输出。

手动触发：`Actions → Deploy → Run workflow`，`app` 填 `<名字>`（在 `apps/` 与 `environment/` 中查找）或 `<scope>/<名字>`，留空表示全部。

## 新增一个应用

1. 新建 `apps/<app>/compose.yaml`，`name:` 设置为项目名。
2. 新建 `apps/<app>/.env` 写入非敏感变量（镜像、端口、profile 等）。
3. 新建 `apps/<app>/app.conf` 声明健康检查：

   ```bash
   APP_NAME=<app>
   HEALTH_CONTAINER=<健康检查的容器名>
   HEALTH_TIMEOUT=180
   HEALTH_URL=http://127.0.0.1:<宿主机端口>/<健康路径>
   REQUIRED_ENV=<缺失即失败的变量名，空格分隔；可省略>
   ```

4. 若需要运行期密钥：
   - 在 `app.conf` 声明 `SECRET_ENV=<变量名，空格分隔>`；
   - 在 GitHub Secrets 建同名 secret（含值）；
   - 在 `deploy.yml` 的「下发运行期密钥」步骤 `env:` 下追加一行 `NAME: ${{ secrets.NAME }}`（GitHub 不支持按变量名动态读取 secret，故需显式声明）。

   CI 会在部署前把 `SECRET_ENV` 声明的变量写入云主机 `/opt/cops/secrets/<app>.env`，`deploy.sh` 自动作为额外的 `--env-file` 加载。**该文件由 CI 全量覆盖，`SECRET_ENV` 必须列出该应用全部需要下发的变量。**
5. 若应用在缺失某个密钥时会静默降级，把它写进 `REQUIRED_ENV`：`deploy.sh` 在启动前检查该变量非空，避免带着空密钥上线。`SECRET_ENV` 负责下发，`REQUIRED_ENV` 负责在服务器侧兜底校验。

## 新增一个环境组件

环境组件（应用依赖的中间件，如 `environment/ptdoc-qdrant/`）与应用的接入方式完全一样：同三个文件、同一套校验与部署流程，只把目录从 `apps/` 换成 `environment/`。额外注意：

- 名字在 `apps/` 与 `environment/` 之间必须唯一；重名会让 CI 在解析阶段直接失败。
- 不要反向依赖 apps 单元：网络与卷都用本项目默认对象，不要写 `external: true` 引用 apps 项目的网络。
- 数据用宿主机绝对路径，且与编排目录解耦（参见 `docs/best-practices.md`「数据与配置分离」）。
- 公网入口不进本仓库：容器只负责监听回环端口，域名/TLS 由云主机的 dockpanel/traefik 管。

## 回滚

把单元 `.env` 中的镜像 tag 改回上一个版本并提交。定时全量重建也会把服务器状态拉回仓库声明。

## native 部署模式

部分服务不交付容器，而是发布包（静态二进制 tarball）+ `systemd` unit。此类应用用 `DEPLOY_MODE=native` 声明，`scripts/deploy.sh` 会把部署交给应用自带的 `native/deploy-native.sh`，仍走同一套「改仓库 → 合入 main → 自动部署」流程。

与 compose 模式的差异：

- 校验阶段不跑 `docker compose config`，改为校验部署脚本语法与期望状态文件齐备。
- 产物在 `apps/<app>/.env` 中用 `NATIVE_ARTIFACT_URL` + `NATIVE_ARTIFACT_SHA256` 锁定，回滚即改回上一版本。CI 在 runner 侧下载并校验后暂存到云主机 `/opt/cops/cache/<app>/`；云主机直连 GitHub 不稳定，部署脚本优先用暂存文件，缺失时才回退下载。
- 需要 root 时，由 `native/deploy-native.sh` 用 `sudo -S` 提权；sudo 密码复用 `DEPLOY_PASSWORD`，经 `SECRET_ENV` 下发到 `/opt/cops/secrets/<app>.env`，脚本读取后立即清除。
- 幂等由脚本内的期望状态哈希保证：期望状态不变时不重启服务。

以 `apps/vectorman/` 为参考实现：

```text
apps/vectorman/
├── .env                    # 产物 URL + sha256、安装根目录
├── app.conf                # DEPLOY_MODE=native、HEALTH_URLS、SECRET_ENV
├── conf/                   # 期望运行时配置（仓库即事实源）
│   ├── config.toml         # dataserver
│   ├── gse-server.toml
│   ├── gse-agent.toml
│   └── console.toml
└── native/
    └── deploy-native.sh    # 下载校验 → 安装 → 迁移 → 重启 → 健康探测
```

## 本地校验

```bash
# 校验编排文件可渲染
docker compose --project-directory apps/lems -f apps/lems/compose.yaml config
docker compose --project-directory environment/ptdoc-qdrant \
  -f environment/ptdoc-qdrant/compose.yaml config

# 查看将要部署的单元（模拟 CI 的变更识别）
git diff --name-only HEAD~1 HEAD -- apps environment | cut -d/ -f1,2 | sort -u
```

## 说明

- `deploy.sh` 使用 `--remove-orphans`：当某个服务从编排文件中移除时，会停掉并删除该项目下多余的容器。它只影响容器，不会删除数据卷，`lems-data` 等持久化数据不受影响。
- 数据不随仓库走：`ptdoc` 的 SQLite 库挂载自 `/opt/ptdoc/data`，`ptdoc-qdrant` 的向量库挂载自 `/opt/ptdoc-qdrant/qdrant-storage`，`lems` 使用命名卷 `lems-data`。GitOps 只管理编排与配置，删容器不丢数据。
- 全量部署不保证执行顺序：`apps/` 与 `environment/` 的单元在一次运行里平级展开（`max-parallel: 1`，按解析顺序）。依赖关系靠健康检查与重试兜住；主机重建后建议先手动触发环境组件。

## 文档

服务负责人请从 [`docs/README.md`](docs/README.md) 开始：

| 文档 | 内容 |
| --- | --- |
| [`docs/onboarding.md`](docs/onboarding.md) | 新增服务接入的完整步骤与模板 |
| [`docs/best-practices.md`](docs/best-practices.md) | 最佳实践与已踩过的坑 |
| [`docs/knowledge.md`](docs/knowledge.md) | 仓库知识：容器镜像源、配置位置与校验方式 |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | 部署失败、容器异常、数据问题的处理 |
