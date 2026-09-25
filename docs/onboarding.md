# 新增服务接入指南

目标是让你的服务进入「改仓库 → 合入 main → 自动部署」的闭环。全程约 15 分钟。

## 前置条件

- [ ] 服务镜像已发布到仓库约定镜像源，如 `ghcr.chenby.cn/abrance/<服务>:vX.Y.Z`。
- [ ] 你确认了容器的监听端口、健康检查路径、需要持久化的目录。
- [ ] 你确认了哪些配置是敏感的（需要密钥下发）。

## 步骤 1：创建应用目录

新增三个文件：`apps/<服务>/compose.yaml`、`.env`、`app.conf`。

`apps/<服务>/.env`（非敏感变量，随仓库提交）：

```bash
# 镜像：统一使用 ghcr.chenby.cn，tag 使用具体版本
MYAPP_IMAGE=ghcr.chenby.cn/abrance/<服务>
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

## 环境组件（应用依赖的中间件）

要接入的是**应用依赖的组件**（数据库、向量库、消息队列、网关等）时，步骤与上面完全一致，只把目录从 `apps/<名字>/` 换成 `environment/<名字>/`：

```bash
git checkout -b 260921-feat-add-qdrant
git add environment/<组件>
git commit -m "feat(<组件>): 纳管 <组件>"
git push -u origin 260921-feat-add-qdrant
```

额外约束：

- [ ] 名字不与 `apps/` 下任何应用重名（重名会让 CI 在解析阶段直接失败）。
- [ ] 不引用 apps 项目的网络或卷（不要写 `external: true`）。
- [ ] 数据用宿主机绝对路径，且该路径与编排目录解耦。
- [ ] 容器只监听回环端口；域名/TLS 入口交给云主机的 dockpanel/traefik，不进仓库。
- [ ] 上游镜像 tag 不带 `v` 前缀时按实际形状写（如 `1.0.6`），并在 `.env` 注释里写明。

部署命令只差一个参数：环境组件是 `scripts/deploy.sh <名字> environment`（应用是 `<名字> apps`，不传则默认 `apps`）。参考实现：`environment/ptdoc-qdrant/`。

## 提交前检查清单

- [ ] 目录名合法（小写字母数字连字符）且与 compose `name:`、容器名一致。
- [ ] 放对位置：应用在 `apps/`，应用依赖的环境组件在 `environment/`，且两边不重名。
- [ ] 镜像使用 `ghcr.chenby.cn/abrance/<服务>` 且 tag 为具体版本（上游不带 `v` 时按实际形状）。
- [ ] 声明了 `pull_policy: always`、`platform: linux/amd64`、`logging` 上限。
- [ ] 健康检查用 GET 探测真实路径。
- [ ] 数据卷用命名卷或绝对路径。
- [ ] 无任何密钥、密码、token 入库。
- [ ] 敏感变量已在 `SECRET_ENV`、GitHub Secrets、`deploy.yml env:` 三处登记。
- [ ] `docker compose config --quiet` 本地通过。

## 附录：native 应用（发布包 + systemd）

发布物不是容器镜像（例如静态二进制 tarball）时，走 native 模式：

1. `apps/<服务>/app.conf` 加 `DEPLOY_MODE=native`、`HEALTH_URLS="<空格分隔的 URL 列表>"`，以及 `SECRET_ENV` / `REQUIRED_ENV`。
2. `apps/<服务>/.env` 用 `NATIVE_ARTIFACT_URL` + `NATIVE_ARTIFACT_SHA256` 锁定产物；CI 会在 runner 侧下载校验并暂存到云主机 `/opt/cops/cache/<服务>/`。
3. `apps/<服务>/conf/` 放期望运行时配置。
4. `apps/<服务>/native/deploy-native.sh` 负责下载、校验、安装、迁移、重启与健康探测；校验阶段会跑 `bash -n`。
5. 若需要 root，`SECRET_ENV` 声明密码变量，并在 `deploy.yml` 的「下发运行期密钥」步骤 `env:` 映射（vectorman 复用 `DEPLOY_PASSWORD`）。

可直接参考 `apps/vectorman/`。

## 附录：k8s 应用（k3s 主机，cloud3）

服务部署到 k3s 主机时走 `DEPLOY_MODE=k8s`。与 compose 的接入步骤对比如下（`apps/model-ocr/` 是最小参考，`apps/model-logcluster/` 带 PVC）：

1. `apps/<服务>/app.conf`：

   ```bash
   APP_NAME=<服务>
   DEPLOY_MODE=k8s
   DEPLOY_TARGET=cloud3
   K8S_NAMESPACE=cops
   K8S_ROLLOUT="deployment/<服务>"
   K8S_HEALTH="<服务>:8080:/healthz"     # 有状态服务探 /readyz
   HEALTH_TIMEOUT=180
   REQUIRED_ENV=""
   SECRET_ENV=""
   ```

2. `apps/<服务>/.env`：镜像 + tag、容器端口、资源限制、域名等，供 `k8s.yaml` 用 `${VAR}` 引用。
   注意 k8s 主机的镜像源是 `ghcr.io`（旧主机的 `ghcr.chenby.cn` 从 cloud3 访问会被 Cloudflare 拦，见 [knowledge.md](knowledge.md) 第 6 节）。

3. `apps/<服务>/k8s.yaml`：多文档 YAML（`---` 分隔），至少包含
   - `Namespace`（`cops`）
   - `Middleware redirect-https`（命名空间级对象，**每个单元都写一份**，apply 幂等，不依赖单元部署顺序）
   - `Deployment`：镜像、`readinessProbe`、资源限制；（有状态服务再加 PVC 与 `volumeMounts`）
   - `Service`（ClusterIP）
   - 两条 `IngressRoute`：`entryPoints: [web]` 挂跳转中间件 + `entryPoints: [websecure]` 带 `tls: {certResolver: letsencrypt}`

4. 无需声明 `SHARED_NETWORKS`：同命名空间用 Service 名当主机名即可跨单元互访。

5. 本地校验：

   ```bash
   scripts/hosts.sh check
   scripts/render-k8s.py apps/<服务> > /dev/null
   EVENT_NAME=workflow_dispatch REQUESTED=<服务> scripts/resolve-units.sh
   ```

6. 提交前确认目标主机已在 `hosts.yaml` 登记，且它对该单元的 `DEPLOY_MODE` 是允许的
   （`scripts/hosts.sh check` 与 resolve 阶段都会校验）。

新增/迁移主机的完整流程见 [cloud3.md](cloud3.md)「九、接入 cops CD」。