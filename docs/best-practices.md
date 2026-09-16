# 最佳实践

每条都给出**做法**与**原因**，多数来自本项目已踩过的坑。假设你刚接手一个要接入 `cops` 的服务。

## 1. 一个服务一个目录，名字即标识

**做法**

- 目录为 `apps/<服务>/`，`<服务>` 只用小写字母、数字和连字符（CI 校验 `^[a-z0-9][a-z0-9-]*$`）。
- `compose.yaml` 里 `name:` 与目录名一致；容器名与 `app.conf` 的 `HEALTH_CONTAINER` 对应。

**原因**：变更识别按 `apps/<服务>/` 前缀归属应用。名字不一致会导致健康检查找不到容器、`--remove-orphans` 清理不到旧容器。

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

## 5. 镜像公开、tag 具体、可复现

**做法**

- 镜像发布到公开 GHCR（`ghcr.io/abrance/<服务>`），云主机可匿名拉取。
- 使用不可变 tag（`vX.Y.Z`），不要用 `latest`。
- 编排里声明 `pull_policy: always` 与 `platform: linux/amd64`（云主机为 x86_64）。

**原因**：`pull_policy: always` 保证同 tag 重新部署会真正拉取；不可变 tag 让回滚与审计有据可依。

**反例（真实教训）**：曾依赖 `swr.cn-north-4.myhuaweicloud.com/ddn-k8s/...` 这类镜像加速地址中转，它对新 tag 常常返回 not found，把简单拉取变成手工搬运。已确认云主机可匿名直连 GHCR，不要再引入中转地址。

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
| `apps/<服务>/**` | 只部署该服务 |
| `scripts/**` 或 `.github/workflows/deploy.yml` | **全量**部署所有服务 |
| 仅 `docs/**`、`README.md` | 不触发任何流水线 |

**原因**：部署逻辑自身变更需要立即对全部应用生效。所以改 `scripts/` 时要意识到影响面是全量。

## 10. 声明日志上限，避免撑爆磁盘

**做法**

```yaml
logging:
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"
```

**原因**：云主机根分区有限，无上限的 json-file 日志会持续增长。本项目所有服务统一声明。

## 11. 回滚靠改 tag

**做法**：把 `apps/<服务>/.env` 里的镜像 tag 改回上一个版本，开 PR 合入。紧急情况下也可在云主机上临时处理，但随后要回补到仓库。

**原因**：仓库是唯一事实源。只改服务器会在下次部署或定时纠偏时被覆盖，问题重现。

## 12. 不要做的事

- 不要把密钥、token、密码写进 `apps/<服务>/.env` 或任何入库文件。
- 不要在云主机上手工修改 `/opt/cops/apps/` 下的文件。
- 不要在编排里使用相对路径挂载数据。
- 不要把 `latest` 作为镜像 tag。
- 不要用 HEAD 请求做健康检查。
- 不要引入镜像中转/加速地址。
- 不要直推 `main`：走分支 + PR。
