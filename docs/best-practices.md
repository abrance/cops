# 最佳实践

每条都给出**做法**与**原因**，多数来自本项目已踩过的坑。假设你刚接手一个要接入 `cops` 的服务。

## 1. 一个单元一个目录，名字即标识

**做法**

- 应用放 `apps/<名字>/`，应用依赖的环境组件（中间件等）放 `environment/<名字>/`；`<名字>` 只用小写字母、数字和连字符（CI 校验 `^[a-z0-9][a-z0-9-]*$`）。
- 两边的目录内容布局完全一致：`compose.yaml` + `.env` + `app.conf`。
- `compose.yaml` 里 `name:` 与目录名一致；容器名与 `app.conf` 的 `HEALTH_CONTAINER` 对应。
- 名字在`apps/` 与 `environment/` 之间必须唯一（密钥文件名与容器名都只看名字，重名会让 CI 在解析阶段直接失败）。

**原因**：变更识别按 `apps/<名字>/` 或 `environment/<名字>/` 前缀归属单元。名字不一致会导致健康检查找不到容器、`--remove-orphans` 清理不到旧容器。

## 2. 期望状态写全，不在云主机手工改

**做法**：所有编排与配置变化都提交到仓库。

**原因**：每次部署会把 `apps/<服务>/` 的内容全量同步覆盖到 `/opt/cops/apps/<服务>`，同时每天定时全量重建一次。手工改动会被覆盖，或造成「服务器与仓库不一致」的漂移。

**需要临时改行为时**：改仓库、开 PR，而不是登服务器。

## 3. 密钥分层：能公开的进仓库，不能公开的进 GitHub Secrets

**做法**

- 非敏感变量（镜像、端口、日志级别等）→ `apps/<服务>/.env`，随仓库提交。
- 敏感变量 → 在 `app.conf` 用 `SECRET_ENV=<变量名>` 声明；值存 GitHub Secrets；并在 `deploy.yml` 的「下发运行期密钥」步骤 `env:` 里追加一行映射。

```bash
# apps/<服务>/app.conf
SECRET_ENV=MY_API_TOKEN MY_DB_PASSWORD
REQUIRED_ENV=MY_API_TOKEN MY_DB_PASSWORD
```

```yaml
# .github/workflows/deploy.yml → 「下发运行期密钥」steps.env
env:
  MY_API_TOKEN: ${{ secrets.MY_API_TOKEN }}
  MY_DB_PASSWORD: ${{ secrets.MY_DB_PASSWORD }}
```

**原因**：仓库是公开仓库，提交即公开。密钥放 GitHub Secrets 后，云主机变成可丢弃的：重装后重跑一次部署就能自愈。CI 通过 stdin 传输密钥，不经过命令行、不落盘到 runner、不打印取值。

**两个必须注意的点**

- GitHub Actions 不支持按变量名动态读取 secret，所以**必须**在 `app.conf` 的 `SECRET_ENV` 和 `deploy.yml` 的 `env:` 两处都声明。
- `/opt/cops/secrets/<服务>.env` 由 CI **全量覆盖**，`SECRET_ENV` 必须列出该服务所有需要下发的变量，漏写会导致该变量在下次部署后消失。

## 4. 数据与配置分离

**做法**：数据用命名卷或宿主机绝对路径挂载。

```yaml
volumes:
  - my-data:/app/data            # 命名卷
  - /opt/myservice/data:/app/data # 或宿主机绝对路径
```

**原因**：本仓库只管编排与配置，`--remove-orphans` 与容器重建都不应影响数据。

**反例（真实教训）**：原 ptdoc 编排用相对路径 `../../data`。当编排文件从 `/opt/ptdoc/deploy/docker-compose` 迁到 `/opt/cops/apps/ptdoc` 后，相对路径会解析到另一个位置，数据库直接「消失」。迁目录时务必改成绝对路径。

## 5. 镜像源统一、tag 具体、可复现

**做法**

- Compose 镜像统一使用 `ghcr.chenby.cn/abrance/<服务>`；完整约定与当前清单见 [knowledge.md](knowledge.md)。
- 镜像名写在 `apps/<服务>/.env` 的 `*_IMAGE` 变量中，变更与 Compose 配置一起走 PR。
- 使用具体版本 tag（`vX.Y.Z`），不要用 `latest`。
- 编排里声明 `pull_policy: always` 与 `platform: linux/amd64`（云主机为 x86_64）。

**原因**：统一镜像源避免部署环境与接入模板不一致；`pull_policy: always` 保证同 tag 重新部署会真正拉取；具体版本 tag 让回滚与审计有据可依。

**反例（真实教训）**：曾依赖 `swr.cn-north-4.myhuaweicloud.com/ddn-k8s/...` 这类未登记的镜像加速地址中转，它对新 tag 常常返回 not found，把简单拉取变成手工搬运。不要随意引入未登记的镜像源或代理地址。

## 6. 健康检查必须探测真实业务接口

**做法**：用 GET 请求真实路径。

```yaml
healthcheck:
  test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost:80/api/health"]
```

**原因**：部署是否成功由健康状态决定，假阳性会掩盖真实故障。

**反例（真实教训）**：`wget --spider` 发送的是 HEAD 请求，而服务路由只接受 GET，返回 404，导致容器长期显示 `unhealthy` 并让部署判定反复失败。

**另一类假阳性**：健康接口返回 200 但业务密钥为空。此时用 `REQUIRED_ENV` 提前拦截（见下条）。

## 7. 把不变量写进 app.conf，让错误在部署阶段暴露

**做法**

```bash
# apps/<服务>/app.conf
APP_NAME=<服务>
HEALTH_CONTAINER=<容器名>
HEALTH_TIMEOUT=180
HEALTH_URL=http://127.0.0.1:<端口>/<健康路径>
SECRET_ENV=<需下发的密钥变量，空格分隔>
REQUIRED_ENV=<缺失即失败的变量，空格分隔>
```

- `REQUIRED_ENV` 在部署脚本启动前检查变量非空。

**原因**：失败应当发生在部署阶段并报出明确原因，而不是上线后由用户发现功能静默失效。

## 8. 保持幂等，用流水线重建而不是手工操作

**做法**：期望状态不变时，重复部署不应有副作用（容器不重建）。需要强制重新部署时用 `workflow_dispatch`。

**原因**：幂等让「再跑一次」成为安全的排障手段，也让定时纠偏不会打扰正常运行的服务。

## 9. 了解变更的部署半径

| 你改了什么 | 会发生什么 |
| --- | --- |
| `apps/<应用>/**` | 只部署该应用 |
| `environment/<组件>/**` | 只部署该环境组件 |
| `scripts/**` 或 `.github/workflows/deploy.yml` | **全量**部署所有单元（`apps/` + `environment/`） |
| 仅 `docs/**`、`README.md` | 不触发任何流水线 |

**原因**：部署逻辑自身变更需要立即对全部应用生效。所以改 `scripts/` 时要意识到影响面是全量。

## 10. 声明资源上限，避免撑爆磁盘或内存

**做法：日志上限。**

```yaml
logging:
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"
```

**做法：占内存或磁盘的东西都要有上界。**

- 容器内存与 CPU：`deploy.resources.limits`，且要与服务自身的并发上界一起看——
  **并发乘单次峰值才是总数**，只卡一边等于没卡。
- 落盘的临时文件、缓存、状态卷：要么在应用里设容量上限，要么写清回收机制（TTL、
  定期清理、人工处置步骤）。有状态服务的卷还要在 `apps/<服务>/` 或
  `docs/troubleshooting.md` 里给出处置流程。
- 镜像与构建缓存由 `scripts/deploy.sh` 的保留窗口回收（`IMAGE_RETENTION_HOURS`，
  默认 120 小时）。
- 入口对请求体的磁盘缓冲不在本仓库（traefik 默认流式转发、不缓冲）；排查 `/tmp`
  增长时先看那里。

**原因**：这是同一类故障的两半——磁盘写满与 OOM 都不在业务日志里留明显痕迹，
只留下"服务突然重启"。云主机根分区有限，无上限的 json-file 日志会持续增长。

**现状（2026-09）**：日志上限所有单元都声明了；内存/CPU 上限目前只有 `model-ocr`
与 `model-logcluster` 声明，`lems`、`ptdoc`、`ptdoc-qdrant` 还没有。新增单元按上面的
做法补齐，不要照抄现有单元的省略。

## 11. 回滚靠改 tag

**做法**：把 `apps/<服务>/.env` 里的镜像 tag 改回上一个版本，开 PR 合入。紧急情况下也可在云主机上临时处理，但随后要回补到仓库。

**原因**：仓库是唯一事实源。只改服务器会在下次部署或定时纠偏时被覆盖，问题重现。

## 12. native 应用：发布包 + systemd

**做法**：没有容器镜像的服务用 `app.conf` 的 `DEPLOY_MODE=native` 声明，把实际部署逻辑放进 `apps/<服务>/native/deploy-native.sh`。

**约定**

- 产物版本在 `.env` 锁定，并校验发布包的 `sha256`，避免同版本号被覆盖后无法复现。
- 产物下载放 CI（runner）侧完成，校验后暂存到云主机；云主机直连 GitHub 常受限，不要假设它能直接拉取发布包。
- 期望运行时配置放 `apps/<服务>/conf/`，部署时覆盖到目标目录，仓库仍是唯一事实源。
- 需要 root 时用 `sudo -S`，密码经 `SECRET_ENV` 下发（复用 `DEPLOY_PASSWORD`），读取后立即从磁盘清除。
- 部署脚本必须幂等：期望状态未变化时不重启服务。

**原因**：不是所有服务都能打成容器。与其为凑格式硬造镜像，不如让仓库继续做唯一事实源，只在部署方式上分叉。`apps/vectorman/` 是参考实现。

## 13. 环境组件（`environment/`）：应用依赖的中间件

**做法**

- 应用依赖的组件（数据库、向量库、消息队列、网关等）放 `environment/<组件>/`，文件布局与 `apps/` 一致。
- 组件不反向依赖 apps 单元：网络、卷都用本项目默认对象，不要写 `external: true` 引用 apps 项目的网络。
- 数据用宿主机绝对路径，且与编排目录解耦（见「数据与配置分离」）。
- 只保证容器监听回环端口；域名与 TLS 入口由云主机的 dockpanel/traefik 管，不进本仓库。
- 上游镜像 tag 不带 `v` 前缀时按实际形状写，并在 `.env` 注释里说明。

**原因**：依赖方向不能倒。如果环境组件引用了 apps 侧创建的网络（`external: true`），一旦那个应用项目被移除或先于组件部署，组件本身就起不来 —— 而它应该是整个环境里最先能独立跑起来的一层。

**参考实现**：`environment/ptdoc-qdrant/`（Qdrant + 本地向量化网关，被 `apps/ptdoc` 依赖）。

## 14. 不要做的事

- 不要把密钥、token、密码写进 `apps/<服务>/.env` 或任何入库文件。
- 不要在云主机上手工修改 `/opt/cops/apps/`、`/opt/cops/environment/` 下的文件。
- 不要在编排里使用相对路径挂载数据。
- 不要把 `latest` 作为镜像 tag。
- 不要用 HEAD 请求做健康检查。
- 不要引入未登记的镜像源或代理地址。
- 不要让环境组件引用 apps 网络/卷（`external: true`）。
- 不要在 `apps/` 与 `environment/` 之间重名。
- 不要直推 `main`：走分支 + PR。
