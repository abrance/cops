# cops

云主机服务的 GitOps CD 仓库。本仓库是部署期望状态的唯一事实源：修改 `apps/<app>/` 下的文件并合入 `main`，GitHub Actions 会把该应用同步到云主机并应用。

## 架构

```text
开发者 / PR ──► cops(main) ──► GitHub Actions ──SSH──► 云主机
                                 │                     ├─ 同步 /opt/cops/apps/<app>
                                 │                     ├─ docker compose pull
                                 │                     └─ up -d + 健康检查
                                 └─ 凭据来自 GitHub Secrets
```

- 触发方式：PR 只做编排校验不部署；合入 `main` 后只部署受影响应用；`workflow_dispatch` 可手动指定或全量；每天定时全量重建以纠正漂移。
- 镜像来源：应用镜像由各自源码仓库构建后推送到公开 GHCR 包，服务器可匿名拉取，本仓库不需要任何 registry 凭据。
- 密钥分层：SSH 主机 / 账号 / 密码放 GitHub Secrets；应用运行期密钥放云主机 `/opt/cops/secrets/<app>.env`（权限 600，不入库）。

## 已纳管应用

| 应用 | 容器 | 镜像 | 说明 |
| --- | --- | --- | --- |
| `lems` | `lems`、`emsdevice` | `ghcr.io/abrance/ems`、`ghcr.io/abrance/emsdevice` | EMS 主服务与 ess_demo Modbus 从站 |
| `ptdoc` | `ptdoc` | `ghcr.io/abrance/ptdoc` | Markdown 文档站；数据保留在 `/opt/ptdoc` |

## 目录结构

```text
.
├── apps/
│   ├── lems/              # 一个目录 = 一个部署单元（一个 docker compose 项目）
│   │   ├── app.conf       # 应用元数据：健康检查容器 / 超时 / 探测地址 / 必需变量
│   │   ├── compose.yaml   # 期望状态编排
│   │   ├── .env           # 非敏感变量（随仓库提交）
│   │   └── emsdevice.json # 服务配置文件
│   └── ptdoc/
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

1. 修改 `apps/<app>/` 下的期望状态并提交到 `main`。
2. 开 PR 后 Actions 先做编排校验，不触碰云主机；合入 `main` 后进入部署。
3. Actions 计算受影响应用列表，对每个应用执行：
   - `docker compose config` 校验编排文件
   - 通过 SSH 将 `apps/<app>/` 同步到 `/opt/cops/apps/<app>/`
   - 在服务器上执行 `scripts/deploy.sh <app>`：拉取镜像 → `up -d` → 等待容器健康 → 探测健康接口
4. 部署失败时 job 非零退出，容器日志会打印到 Actions 输出。

手动触发：`Actions → Deploy → Run workflow`，`app` 留空表示全部应用。

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

## 回滚

把 `apps/<app>/.env` 中的镜像 tag 改回上一个版本并提交。定时全量重建也会把服务器状态拉回仓库声明。

## 本地校验

```bash
# 校验编排文件可渲染
docker compose --project-directory apps/lems -f apps/lems/compose.yaml config

# 查看将要部署的应用（模拟 CI 的变更识别）
git diff --name-only HEAD~1 HEAD -- apps | cut -d/ -f2 | sort -u
```

## 说明

- `deploy.sh` 使用 `--remove-orphans`：当某个服务从编排文件中移除时，会停掉并删除该项目下多余的容器。它只影响容器，不会删除数据卷，`lems-data` 等持久化数据不受影响。
- 数据不随仓库走：`ptdoc` 的 SQLite 库挂载自 `/opt/ptdoc/data`，`lems` 使用命名卷 `lems-data`。GitOps 只管理编排与配置，删容器不丢数据。

## 文档

服务负责人请从 [`docs/README.md`](docs/README.md) 开始：

| 文档 | 内容 |
| --- | --- |
| [`docs/onboarding.md`](docs/onboarding.md) | 新增服务接入的完整步骤与模板 |
| [`docs/best-practices.md`](docs/best-practices.md) | 最佳实践与已踩过的坑 |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | 部署失败、容器异常、数据问题的处理 |
