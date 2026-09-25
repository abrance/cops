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
- 密钥分层：SSH 主机 / 账号 / 私钥放 GitHub Secrets；运行期密钥放云主机 `/opt/cops/secrets/<名字>.env`（权限 600，不入库）。
- 部署模式：默认 `compose`（容器编排）；`app.conf` 声明 `DEPLOY_MODE=native` 的单元走发布包 + systemd 部署，见下文「native 部署模式」。

## 已纳管应用

| 应用 | 容器 | 镜像 | 说明 |
| --- | --- | --- | --- |
| `lems` | `lems`、`emsdevice` | `ghcr.chenby.cn/abrance/ems`、`ghcr.chenby.cn/abrance/emsdevice` | EMS 主服务与 ess_demo Modbus 从站 |
| `model-ocr` | `model-ocr` | `ghcr.chenby.cn/abrance/modelman-ocr` | PP-OCR 文字识别服务（MNN/CPU）；已迁 cloud3（k8s），lems 经公网入口 `https://ocr.xiaoyxq.top` 调用；源码仓库 [abrance/modelman](https://github.com/abrance/modelman) |
| `model-logcluster` | `model-logcluster` | `ghcr.chenby.cn/abrance/modelman-logcluster` | Drain3 日志模板聚类服务（Python/FastAPI）；只监听 `127.0.0.1:9103`；**有状态**，模板树持久化在命名卷 `model-logcluster_state`；源码仓库 [abrance/modelman](https://github.com/abrance/modelman) |
| `ptdoc` | `ptdoc` | `ghcr.chenby.cn/abrance/ptdoc` | Markdown 文档站；数据保留在 `/opt/ptdoc` |
| `vectorman` | 无（systemd） | GitHub Releases 静态二进制包 | GSE 采集链路的 6 个组件，native 部署，数据保留在 `/opt/vectorman` |

单元部署到哪台主机由 `app.conf` 的 `DEPLOY_TARGET` 声明（不写 = `default`），可选值见 [`hosts.yaml`](hosts.yaml)。上表所有单元当前都在 `default`。

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
├── hosts.yaml             # 部署目标主机注册表（主机 → 部署驱动 + Secret 名字）
├── scripts/
│   ├── deploy.sh          # 在云主机上执行的部署脚本（compose / native）
│   ├── deploy-k8s.sh      # 在 k3s 主机上执行的部署脚本（kubectl apply + rollout + 探活）
│   ├── hosts.sh           # 查询 hosts.yaml（CI 与本地排障共用）
│   ├── check-registries.sh # 镜像源守卫：*_IMAGE 必须在该主机允许的 registry 内
│   ├── resolve-units.sh   # 计算本次要部署哪些单元（CI 的 resolve job 调用）
│   └── render-k8s.py      # 渲染 k8s 单元的 ${VAR}（在 runner 侧执行）
└── .github/workflows/
    └── deploy.yml         # 解析变更 → 校验 → 部署
```

## GitHub Secrets

在 `Settings → Secrets and variables → Actions` 配置：

| 名称 | 必填 | 说明 |
| --- | --- | --- |
| `DEPLOY_HOST` | 是 | 云主机地址 |
| `DEPLOY_USER` | 是 | SSH 用户 |
| `DEPLOY_SSH_KEY` | 是 | 部署用户对应的 SSH 私钥（整份 PEM，不设口令） |
| `DEPLOY_PASSWORD` | 否 | sudo 密码，仅 `DEPLOY_MODE=native` 且需提权的单元（vectorman）用 |
| `DEPLOY_PORT` | 否 | SSH 端口，默认 `22` |
| `DEPLOY_KNOWN_HOSTS` | 否 | 服务器 SSH 主机公钥，建议固定（不配置时用 `ssh-keyscan` 临时获取） |
| `PTDOC_DATA_KEY` | 是 | `ptdoc` 运行期密钥，用于加解密七牛 SecretKey；部署时下发到 `/opt/cops/secrets/ptdoc.env` |

主机凭据按**每台主机一组**配置，名字登记在 `hosts.yaml`，值在 `deploy.yml` 的 `env:` 段映射（GitHub 不支持按变量名动态读 secret）。当前两台：

| 主机 | 部署驱动 | 需要的 Secret |
| --- | --- | --- |
| `default`（现有云主机） | compose / native | `DEPLOY_HOST`、`DEPLOY_USER`、`DEPLOY_SSH_KEY`（`DEPLOY_PORT` 未配置=默认 22；`DEPLOY_KNOWN_HOSTS` 未配置时用 `ssh-keyscan`） |
| `cloud3`（k3s 单机，见 [docs/cloud3.md](docs/cloud3.md)） | k8s | `CLOUD3_DEPLOY_HOST`、`CLOUD3_DEPLOY_USER`、`CLOUD3_DEPLOY_SSH_KEY`、`CLOUD3_DEPLOY_PORT`、`CLOUD3_DEPLOY_KNOWN_HOSTS` |

每台主机的 **host / user / key 必填**；**port 缺省 22**；**known_hosts 缺省时用 `ssh-keyscan` 临时获取**（建议固定下来）。

每台主机还声明两组策略字段：

| 字段 | 作用 |
| --- | --- |
| `drivers` | 该主机允许的部署模式（`compose` / `native` / `k8s`）；单元的 `DEPLOY_MODE` 必须在此列表内 |
| `registries` | 该主机允许的镜像源（如 `ghcr.chenby.cn docker.io` 与 `ghcr.io`）；单元的 `*_IMAGE` 必须在此列表内，由 `scripts/check-registries.sh` 在 PR 阶段强制 |

`registries` 存在的原因：镜像源按主机不同——旧主机用 `ghcr.chenby.cn`（该站只对它放行），cloud3 只能用 `ghcr.io`（访问前者会被 Cloudflare 拦成 403）。谁把 `*_IMAGE` 的 registry 换回去，PR 就红，不会拖到部署时才发现拉不动镜像。

新增主机：在 `hosts.yaml` 加一段 → 建这 5 个 secret → 在 `deploy.yml` 的 `env:` 段加 5 行映射。`scripts/hosts.sh check` 会校验注册表结构。

目标主机上的前置（一次性）：部署目录必须存在且对部署用户可写，否则同步步骤会报 `mkdir: cannot create directory '/opt/cops': Permission denied`。

```bash
sudo mkdir -p /opt/cops/secrets && sudo chown -R <部署用户>:<部署用户> /opt/cops
```

应用运行期密钥统一放 GitHub Secrets，由 CI 在部署前写入云主机的 `/opt/cops/secrets/<app>.env`（权限 600，不入库）。密钥通过 stdin 传输，不经过命令行，也不会落盘到 runner。

## 部署流程

1. 修改 `apps/<app>/`（应用）或 `environment/<name>/`（环境组件）下的期望状态并提交到 `main`。
2. 开 PR 后 Actions 先做编排校验，不触碰云主机；合入 `main` 后进入部署。
3. Actions 计算受影响单元列表（`<scope>/<名字>`，含每个单元的 `mode` 与 `target`），对每个单元执行：
   - 先跑镜像源守卫 `scripts/check-registries.sh`（单元的 `*_IMAGE` 必须在该主机的 `registries` 白名单内）
   - 再按模式校验：compose 跑 `docker compose config`；native 校验脚本与期望状态；k8s 跑 `scripts/render-k8s.py` 渲染
   - 通过 SSH 将目录同步到目标主机的 `/opt/cops/<scope>/<名字>/`（k8s 单元连渲染产物 `rendered.yaml` 一起同步）
   - 在目标主机上执行：compose/native 走 `scripts/deploy.sh`（拉镜像 → `up -d` → 等健康 → 探活）；k8s 走 `scripts/deploy-k8s.sh`（`kubectl apply` → `rollout status` → 探 Service 的 ClusterIP → 可选探公网入口）
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
6. 若需要与另一个单元（如 `apps/model-ocr`）的容器直接互访，见下节「跨单元互访」。

## 跨单元互访

不同单元的容器属于不同的 compose 项目，默认在两个网络里，互相不可达；而把服务端口绑到宿主机回环（`127.0.0.1:xxxx`）后，别的容器也访问不到宿主机回环。同机单元需要互访时，用一张固定名字的共享网络（跨主机则走公网入口，见 model-ocr 与 lems 的现状）：

1. 双方都在 `app.conf` 里声明同一张网络（`deploy.sh` 会幂等创建，不依赖单元的部署顺序）：

   ```bash
   SHARED_NETWORKS="cops-shared"
   ```

2. 双方 `compose.yaml` 都声明为 `external`，并让需要互访的服务加入：

   ```yaml
   services:
     lems:
       networks:
         - default
         - shared
   networks:
     shared:
       external: true
       name: cops-shared
   ```

3. 调用方用**容器名**当主机名，例如 `OCR_BASE_URL=http://model-ocr:8080`（写进调用方 `.env`）。

为什么网络要 `external` 且由 `deploy.sh` 创建：若两边都让 compose 自己创建同一名字的网络，先创建的那个会带上自己的项目标签，后一个单元执行时会因为标签不匹配直接报错。`deploy.sh` 按 `SHARED_NETWORKS` 幂等创建，就绕开了这个坑，也不依赖单元的部署顺序（全量部署不保证顺序）。

共享网络不改变对外暴露方式：被调用方仍只绑回环，公网入口与鉴权由宿主机反向代理决定。

> 当前仓库里没有在用 `SHARED_NETWORKS` 的单元（`lems` 与 `model-ocr` 的同机直连方案随 model-ocr 迁到 cloud3 而废弃）；这段保留作同机互访的参考做法。

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
- 需要 root 时，由 `native/deploy-native.sh` 用 `sudo -S` 提权；sudo 密码取 `DEPLOY_PASSWORD`，经 `SECRET_ENV` 下发到 `/opt/cops/secrets/<app>.env`，脚本读取后立即清除。
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

## k8s 部署模式

k3s 主机上的服务用 `DEPLOY_MODE=k8s` 声明，单元目录放 `k8s.yaml`（多文档 YAML）而不是 `compose.yaml`：

```text
apps/<name>/
├── app.conf      # DEPLOY_MODE=k8s / DEPLOY_TARGET=cloud3 / K8S_NAMESPACE / K8S_ROLLOUT / K8S_HEALTH
├── .env          # 镜像 + tag、端口、资源限制、域名（k8s.yaml 里用占位符引用）
└── k8s.yaml      # Deployment + Service (+ PVC) (+ IngressRoute)
```

与 compose 模式的差异：

- **变量渲染**：k8s 不认 `${VAR}`，由 `scripts/render-k8s.py` 在 runner 侧渲染成 `rendered.yaml`，再同步到主机。变量取自单元的 `.env`（镜像/端口/资源/域名）与 `app.conf`（`K8S_NAMESPACE` 等部署元数据，同名键覆盖 `.env`）。渲染时**未定义的变量直接失败**（`envsubst` 会静默替换成空串，把端口/镜像 tag 打成空值）。
  - 限制：渲染器不解析 YAML 结构（不引入 YAML 库依赖），因此**注释里也不能出现字面量占位符**——需要在注释里举例时写文字描述。
- **健康检查**：compose 靠 `HEALTH_CONTAINER` + `HEALTH_URL`；k8s 靠 manifest 里的 `readinessProbe`（由 kubelet 执行），`deploy-k8s.sh` 只做 `rollout status` 与探活，`K8S_HEALTH="Service:端口:路径"` 会从主机直接 curl Service 的 ClusterIP。
- **入口与证书**：容器不需要绑定宿主机回环端口；对外暴露用 `IngressRoute`，证书由 k3s 自带 Traefik 的 ACME 自动签发。**一条 IngressRoute 必须拆成两条**（`web` 跳转 + `websecure` 带 `tls.certResolver`），否则 80 端口和证书挑战都会 404，原因见 [cloud3.md](cloud3.md) 的坑清单。
- **镜像源**：k3s 主机用 `ghcr.io` 直连，旧主机用 `ghcr.chenby.cn`。按主机的差异见 [knowledge.md](docs/knowledge.md) 第 6 节。
- **单元互访**：k8s 用同一命名空间的 Service 名当主机名，不需要 `SHARED_NETWORKS`。
- **状态数据**：用 PVC（`local-path`），不再是 Docker 命名卷。

k8s 单元的 `app.conf` 字段：

```bash
DEPLOY_MODE=k8s
DEPLOY_TARGET=cloud3
K8S_NAMESPACE=cops
K8S_ROLLOUT="deployment/model-ocr"     # 需要等待 rollout 的对象，空格分隔可多个
K8S_HEALTH="model-ocr:8080:/healthz"   # Service:端口:路径，从主机 curl ClusterIP 探活
PUBLIC_URL="https://ocr.xiaoyxq.top/healthz"   # 可选：再从公网探一次
HEALTH_TIMEOUT=180
```

参考实现见 `apps/model-ocr/` 与 `apps/model-logcluster/`（后者带 PVC）。

## 本地校验

```bash
# 校验编排文件可渲染
docker compose --project-directory apps/lems -f apps/lems/compose.yaml config
docker compose --project-directory environment/ptdoc-qdrant \
  -f environment/ptdoc-qdrant/compose.yaml config

# 查看将要部署的单元（与 CI 的 resolve 完全同一份逻辑）
EVENT_NAME=push BASE_SHA=HEAD~1 HEAD_SHA=HEAD scripts/resolve-units.sh

# 主机注册表结构自检（缺字段/未知字段/非法驱动都会失败）
scripts/hosts.sh check

# 镜像源守卫（与 CI 的 validate 同一份逻辑）
scripts/check-registries.sh apps/model-ocr cloud3
scripts/check-registries.sh apps/lems default

# k8s 单元的渲染校验（未定义变量、残留 ${...}、缺 apiVersion/kind 都会失败）
scripts/render-k8s.py apps/model-ocr > /dev/null

# 主机侧部署脚本语法
bash -n scripts/deploy.sh scripts/deploy-k8s.sh
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
