# 新增服务接入指南

目标是让你的服务进入「改仓库 → 合入 main → 自动部署」的闭环。全程约 15 分钟。

## 前置条件

- [ ] 服务镜像已发布到公开 GHCR，如 `ghcr.io/abrance/<服务>:vX.Y.Z`，云主机可匿名拉取。
- [ ] 你确认了容器的监听端口、健康检查路径、需要持久化的目录。
- [ ] 你确认了哪些配置是敏感的（需要密钥下发）。

## 步骤 1：创建应用目录

新增三个文件：`apps/<服务>/compose.yaml`、`.env`、`app.conf`。

`apps/<服务>/.env`（非敏感变量，随仓库提交）：

```bash
# 镜像：公开 GHCR 包，云主机可匿名拉取
MYAPP_IMAGE=ghcr.io/abrance/<服务>
MYAPP_IMAGE_TAG=v1.0.0

# 端口与运行环境
MYAPP_PORT=18080
APP_PROFILE=prod
```

`apps/<服务>/compose.yaml`：

```yaml
name: <服务>          # 必须与目录名一致

services:
  <服务>:
    image: ${MYAPP_IMAGE}:${MYAPP_IMAGE_TAG}
    container_name: <服务>
    restart: unless-stopped
    pull_policy: always
    platform: linux/amd64
    environment:
      APP_PROFILE: ${APP_PROFILE}
    ports:
      - "${MYAPP_PORT}:8080"
    volumes:
      # 数据用命名卷或宿主机绝对路径，不要用相对路径
      - myapp-data:/app/data
    healthcheck:
      # 用 GET 探测真实路径
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost:8080/api/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  myapp-data:
```

`apps/<服务>/app.conf`：

```bash
APP_NAME=<服务>
HEALTH_CONTAINER=<容器名>
HEALTH_TIMEOUT=180
HEALTH_URL=http://127.0.0.1:18080/api/health
# 敏感变量（如需）：
# SECRET_ENV=MYAPP_API_KEY
# REQUIRED_ENV=MYAPP_API_KEY
```

## 步骤 2：运行期密钥（如需要）

敏感配置不能写进 `.env`。按下面三处登记，缺一不可：

1. `apps/<服务>/app.conf` 声明变量名，并加 `REQUIRED_ENV` 兜底：

   ```bash
   SECRET_ENV=MYAPP_API_KEY
   REQUIRED_ENV=MYAPP_API_KEY
   ```

2. GitHub 仓库 `Settings → Secrets and variables → Actions` 新建同名 secret `MYAPP_API_KEY`。

3. `.github/workflows/deploy.yml` 的「下发运行期密钥」步骤 `env:` 追加映射：

   ```yaml
   env:
     PTDOC_DATA_KEY: ${{ secrets.PTDOC_DATA_KEY }}
     MYAPP_API_KEY: ${{ secrets.MYAPP_API_KEY }}
   ```

   第 3 步不能省：GitHub Actions 不支持按变量名动态读取 secret。

部署前 CI 会把 `SECRET_ENV` 声明的变量写入云主机 `/opt/cops/secrets/<服务>.env`（权限 600），部署脚本自动作为额外的 `--env-file` 加载。

> 注意：该文件由 CI 全量覆盖，`SECRET_ENV` 必须列出该服务全部需要下发的变量。

## 步骤 3：云主机侧准备（仅数据目录需要）

密钥文件由 CI 创建，无需手工准备。但如果你的服务挂载的是**宿主机绝对路径**，需要先确保目录存在且容器可写：

```bash
# 在云主机执行
mkdir -p /opt/<服务>/data
```

若容器以非 root 运行，注意宿主机目录属主。命名卷（如 `myapp-data`）无需此步。

## 步骤 4：本地校验

```bash
# 编排文件可渲染（不启动容器）
docker compose --project-directory apps/<服务> -f apps/<服务>/compose.yaml config --quiet
# 查看渲染后的端口、挂载、镜像、变量
docker compose --project-directory apps/<服务> -f apps/<服务>/compose.yaml config

# YAML 语法（若本地有 python3 + pyyaml）
python3 -c "import yaml; yaml.safe_load(open('apps/<服务>/compose.yaml'))"

# 部署脚本语法（若改过 scripts/）
bash -n scripts/deploy.sh
```

`docker compose config --quiet` 是 CI 校验的同一命令，本地先过一遍能省一次往返。

## 步骤 5：分支 + PR

分支命名：`YYMMDD-<类型>-<简述>`，类型用 `feat` / `fix` / `chore` / `docs` / `refactor`。

```bash
git checkout -b 260916-feat-add-myapp
git add apps/<服务>
git commit -m "feat(myapp): 纳管 myapp"
git push -u origin 260916-feat-add-myapp
```

然后在 GitHub 开 PR 到 `main`。

**PR 阶段只做编排校验，不会部署**。确认 `解析待部署应用` 与 `校验 <服务>` 两个 job 为绿。

## 步骤 6：合入并观察

合并后流水线自动执行：识别受影响服务 → 同步文件 → 下发密钥 → 拉镜像 → `up -d` → 等待健康 → 探测接口。

在 `Actions` 里确认「部署 <服务>」为绿。部署日志会打印容器状态与健康探测结果。

## 步骤 7：验证清单

- [ ] `Actions` 中「部署 <服务>」success。
- [ ] 云主机 `docker compose -f /opt/cops/apps/<服务>/compose.yaml ps` 显示 `Up (healthy)`。
- [ ] 服务对外端口可访问。
- [ ] `docker logs <容器>` 无报错。
- [ ] 数据目录内容仍在（若有历史数据）。
- [ ] 再做一次 `workflow_dispatch` 触发，确认幂等（容器不重建）。

## 提交前检查清单

- [ ] 目录名合法（小写字母数字连字符）且与 compose `name:`、容器名一致。
- [ ] 镜像为公开 GHCR 且 tag 为 `vX.Y.Z`。
- [ ] 声明了 `pull_policy: always`、`platform: linux/amd64`、`logging` 上限。
- [ ] 健康检查用 GET 探测真实路径。
- [ ] 数据卷用命名卷或绝对路径。
- [ ] 无任何密钥、密码、token 入库。
- [ ] 敏感变量已在 `SECRET_ENV`、GitHub Secrets、`deploy.yml env:` 三处登记。
- [ ] `docker compose config --quiet` 本地通过。

## 附录：native 应用（发布包 + systemd）

发布物不是容器镜像（例如静态二进制 tarball）时，走 native 模式：

1. `apps/<服务>/app.conf` 加 `DEPLOY_MODE=native`、`HEALTH_URLS="<空格分隔的 URL 列表>"`，以及 `SECRET_ENV` / `REQUIRED_ENV`。
2. `apps/<服务>/.env` 锁定版本与发布包 `sha256`。
3. `apps/<服务>/conf/` 放期望运行时配置。
4. `apps/<服务>/native/deploy-native.sh` 负责下载、校验、安装、迁移、重启与健康探测；校验阶段会跑 `bash -n`。
5. 若需要 root，`SECRET_ENV` 声明密码变量，并在 `deploy.yml` 的「下发运行期密钥」步骤 `env:` 映射（vectorman 复用 `DEPLOY_PASSWORD`）。

可直接参考 `apps/vectorman/`。
