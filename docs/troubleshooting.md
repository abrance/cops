# 排障手册

先定位失败发生在哪一步，再对症处理。流水线各步骤对应如下。

```text
解析待部署单元 → 校验 <scope>/<名字> → 校验部署凭据 → 配置 SSH 主机密钥
→ 同步期望状态文件 → 下发运行期密钥 → 执行部署
                                        ├─ 拉取镜像
                                        ├─ 应用期望状态
                                        ├─ 等待容器健康
                                        └─ 探测健康接口
```

## 快速定位

| 现象 | 先看 |
| --- | --- |
| 某个 job 红 | Actions 里展开该 job 的失败步骤 |
| 「部署 <scope>/<名字>」红 | 该 job 的「执行部署」步骤输出，会打印容器日志尾部 |
| 服务不可访问但部署绿 | 云主机上 `docker compose ... ps` 与 `docker logs` |
| 只想重新部署一次 | Actions → Deploy → Run workflow，`app` 填 `<名字>` 或 `<scope>/<名字>` |
| 不确定会部署哪些单元 | job「解析待部署单元」的输出，`待部署单元: [{"scope":..,"name":..}]` |

## 部署失败

### 找不到部署单元 / 名字冲突

```text
找不到部署单元 nope：apps/ 与 environment/ 下都没有这个目录
名字在 apps/ 与 environment/ 之间冲突: ptdoc
```

第一种：手动触发时填的名字写错了，或者同名目录不存在。第二种：同一个名字同时出现在 `apps/` 和 `environment/` 下（密钥文件与容器名都只看名字，所以必须全局唯一），删掉或重命名其中一个。

### 缺少 GitHub Actions secret

```text
缺少 GitHub Actions secret: DEPLOY_HOST DEPLOY_USER DEPLOY_SSH_KEY
```

SSH 部署凭据缺失。到 `Settings → Secrets and variables → Actions` 配置。这三个是仓库级必备：

| 名称 | 说明 |
| --- | --- |
| `DEPLOY_HOST` | 云主机地址 |
| `DEPLOY_USER` | SSH 用户 |
| `DEPLOY_SSH_KEY` | 该用户的 SSH 私钥（不设口令） |
| `DEPLOY_KNOWN_HOSTS` | 主机公钥（可选，建议固定） |
| `DEPLOY_PASSWORD` | sudo 密码（可选，仅 vectorman native 部署用） |

若报的是你自己的业务密钥（如 `MYAPP_API_KEY`），说明「下发运行期密钥」步骤里没有该变量：检查 `app.conf` 的 `SECRET_ENV` 与 `deploy.yml` 的 `env:` 两处是否都写了。

套路同上：`deploy.yml` 里任何 `$NAME` 形式的校验都需要对应 step（或 job）的 `env:` 映射，secret 不会自动变成环境变量。job 级 `env:` 覆盖所有步骤，`${!name}` 间接取值也只有环境变量里存在的名字才能取到。

### 缺少必需变量

```text
==> [<服务>] 缺少必需变量 MYAPP_API_KEY，请写入 /opt/cops/secrets/<服务>.env
```

这是 `REQUIRED_ENV` 的兜底检查，说明密钥没有进到云主机。原因通常是上一条：secret 未配置或未在 `deploy.yml` 声明。修正后重新部署即可；无需手工在服务器创建文件（会被 CI 覆盖）。

### 校验编排文件失败

本地用同一命令复现：

```bash
docker compose --project-directory apps/<服务> -f apps/<服务>/compose.yaml config
docker compose --project-directory environment/<组件> -f environment/<组件>/compose.yaml config
```

常见原因：YAML 缩进错误、变量名拼写不一致、`volumes:` 顶层未声明命名卷。

### SSH 主机密钥校验失败

报 `Host key verification failed`。若配置了 `DEPLOY_KNOWN_HOSTS`，确认其内容与云主机当前公钥一致（主机重装后会变化）。获取方式：

```bash
ssh-keyscan -t ed25519,rsa <云主机地址>
```

### SSH 密钥认证失败

报 `Permission denied (publickey)`。`DEPLOY_SSH_KEY` 与云主机 `DEPLOY_USER` 的 `~/.ssh/authorized_keys` 不匹配，或私钥带了口令（CI 无法交互输入）。排查：

```bash
ssh-keygen -y -f <私钥文件>   # 有口令会提示输入，CI 用不了
ssh -i <私钥文件> -o IdentitiesOnly=yes <DEPLOY_USER>@<DEPLOY_HOST> true
```

### 拉取镜像失败

报 `manifest unknown` 或 `denied`。检查：

- 镜像是否已发布到 `ghcr.chenby.cn/abrance/<服务>`，tag 是否存在于远程。
- 镜像源是否可被目标主机访问；当前仓库不保存 registry 凭据。

在云主机上直接验证：

```bash
docker pull ghcr.chenby.cn/abrance/<服务>:vX.Y.Z
```

若 pull 长时间停在 `Pulling fs layer`、没有任何 `Pull complete`，而 `docker manifest inspect <镜像>` 秒回，则不是 registry 的问题，而是 blob 回源 `pkg-containers.githubusercontent.com` 不通/极慢（云主机直连 `ghcr.io` 就是这种表现）。处理：改用 `ghcr.chenby.cn` 路径拉取，不要反复重试直连。

### 健康探测失败 `curl: (56) Recv failure: Connection reset by peer`

容器状态已经是 `running`，但端口还没开始监听——典型是没有 `compose healthcheck` 的服务（如 `ptdoc-qdrant` 的网关要加载本地模型）启动后要几秒才就绪。`deploy.sh` 会在 `HEALTH_TIMEOUT` 秒内每 3 秒重试一次，超时后才失败，并打印尝试次数与最后一次错误。

还失败就按顺序查：`docker logs --tail 50 <容器>` → 在云主机上 `curl -v <HEALTH_URL>` → 确认 `app.conf` 的 `HEALTH_URL` 端口与 `compose.yaml` 的映射一致。若服务永远起不来，考虑给它加 `compose healthcheck`（镜像里没有 `curl`/`wget` 时，用容器自带的探测能力或补一个探测子命令）。

## 容器 unhealthy

### 查看状态与日志

```bash
docker compose -f /opt/cops/<scope>/<名字>/compose.yaml ps
docker inspect -f '{{json .State.Health}}' <容器> | head -c 500
docker logs --tail 100 <容器>
```

### 健康检查本身就是错的

若容器内服务明明正常，但状态一直是 `unhealthy`，检查健康检查用的是不是 HEAD 请求。真实教训：`wget --spider` 发 HEAD，路由只接受 GET，返回 404。改成 GET：

```yaml
test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost:80/api/health"]
```

### 服务启动就崩

看 `docker logs`。常见原因是缺环境变量或密钥无效。若属于「有密钥才正常」的变量，补上 `REQUIRED_ENV` 让它在部署阶段就失败，而不是以 unhealthy 的形式反复重试。

## 数据问题

### 「数据不见了」

先确认挂载来源，而不是怀疑部署：

```bash
docker inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' <容器>
ls -la /opt/<服务>/data
```

最常见原因是编排里用了相对路径（如 `../../data`），随编排文件位置变化而解析到别处。改用绝对路径或命名卷。

### 权限不足

宿主机挂载目录属主与容器运行用户不一致会导致写入失败。检查目录属主，必要时调整 `mkdir -p` 时的属主或让容器以对应用户运行。

## 手工触发与回滚

**强制重新部署**（不修改仓库）：

Actions → Deploy → Run workflow → `app` 填 `<名字>`（在 `apps/` 与 `environment/` 中查找）或 `<scope>/<名字>`。因为 `pull_policy: always`，同 tag 也会重新拉取镜像。

**回滚**：

1. 把单元 `.env` 的镜像 tag 改回上一个版本（应用 `apps/<服务>/.env`，环境组件 `environment/<组件>/.env`），例如把 `v1.0.10` 改回 `v1.0.9`。
2. 开 PR 合入 `main`。

紧急情况下可先在云主机临时处理，但必须随后回补到仓库，否则下次部署或定时纠偏会覆盖。

### 有状态单元的回滚：`model-logcluster`

`model-logcluster` 的模板树落在命名卷 `model-logcluster_state` 里，**回滚镜像不会回滚状态**。
如果旧镜像与状态里的 `schema_version` 或聚类参数（`SIM_TH` 等）不一致，服务会降级：
`/readyz` 返回 503、容器 `unhealthy`、业务端点全部 503，但**不覆盖**旧状态。
部署会在「等待容器健康」步骤失败并打印日志尾部：

```text
state unavailable, serving /readyz 503: 状态文件与当前聚类参数不兼容（...）：
  sim_th: 0.6 -> 0.4。改参数后继续用旧模板会让输出静默变化，因此拒绝启动。
```

这不是故障而是拦截：宁可让回滚失败，也不要拿旧参数去解释新学到的模板。两条出路：

- 想回到旧版本：把参数（`apps/model-logcluster/.env` 里的 `MODEL_LOGCLUSTER_SIM_TH` 等）
  也改回与旧镜像一致，让状态重新兼容；
- 确认旧状态不需要了：备份后清空状态再部署。**清空等于丢掉已累积的模板，簇 ID 会从 1 重新开始**，
  调用方看到的结果会变。

```bash
# 备份
docker run --rm -v model-logcluster_state:/s alpine \
  tar cz -C /s . > /tmp/logcluster-state-$(date +%F).tgz
# 清空
cd /opt/cops/apps/model-logcluster
docker compose --env-file .env stop
docker volume rm model-logcluster_state
docker compose --env-file .env up -d
```

确认当前状态（schema 版本、参数、模板数）而不是猜：

```bash
docker run --rm -v model-logcluster_state:/s alpine cat /s/drain_state.json
docker exec model-logcluster python -c "import json,urllib.request as u;print(u.urlopen('http://127.0.0.1:8080/models').read().decode())"
```

## 常见问答

**为什么我改了 docs 但什么也没跑？**

流水线只在 `apps/**`、`environment/**`、`scripts/**`、workflow 自身变更时触发。仅文档变更不会有 run。

**为什么环境组件没看到「下发运行期密钥」？**

该单元没在 `app.conf` 声明 `SECRET_ENV`，job 会打印「未声明 SECRET_ENV，跳过分发」，属正常。

**环境组件和应用会按顺序部署吗？**

不保证。一次运行里 `apps/` 与 `environment/` 平级展开、按解析顺序串行执行（`max-parallel: 1`）。依赖关系靠各自的健康检查与重试兜住；主机重建后建议先 `workflow_dispatch` 触发环境组件，再触发应用。

**为什么 PR 里没有部署？**

设计如此：PR 只跑编排校验，合入 `main` 才部署。

**为什么我只改了一个服务，却部署了全部？**

你改动了 `scripts/**` 或 workflow 本身，这被判定为部署逻辑变更，会全量部署。

**为什么我手工改的服务器文件消失了？**

`/opt/cops/apps/<名字>`、`/opt/cops/environment/<名字>` 每次部署由 CI 全量覆盖。所有变更请回仓库。

**为什么容器没重建？**

期望状态与线上一致（幂等）。需要强制重建用 `workflow_dispatch`，或改一个会改变容器定义的值。

## k8s 单元（cloud3）

### 镜像源守卫失败：`不在允许列表`

```
主机 cloud3 允许的 registry：ghcr.io
apps/xxx 里有镜像不在允许列表：XXX_IMAGE=ghcr.chenby.cn/abrance/xxx（registry ghcr.chenby.cn）
```

registry 是**按主机**不同的：旧主机用 `ghcr.chenby.cn`（该站只对它放行），cloud3 只能用 `ghcr.io`（访问前者会被 Cloudflare 拦成 403）。
处理：把该单元的 `*_IMAGE` 改成目标主机允许的 registry，并确认镜像在该站可拉取。
**通常不需要动这一行**——升级版本只改 `*_IMAGE_TAG`；出现这条报错多半是复制了旧模板或把整行覆盖了。
白名单在 `hosts.yaml` 的 `registries` 字段，本地可用 `scripts/check-registries.sh <单元目录> <主机>` 复现。

### 渲染失败：`引用了 .env 里没有定义的变量`

`scripts/render-k8s.py` 在 runner 侧执行，未定义的 `${VAR}` 会直接失败并列出变量名与行号。
处理：把变量补进单元的 `.env`，或从 `k8s.yaml` 里删掉该引用。**不要**改成 `${VAR:-默认值}`——
本渲染器不支持 bash 默认值语法，会以"渲染后仍残留 `${...}`"报错。

### `DEPLOY_TARGET` 相关报错

- `不在 hosts.yaml 中`：`app.conf` 声明的目标主机名与 `hosts.yaml` 里的键不一致。
- `DEPLOY_MODE 与主机 drivers 不匹配`：例如单元是 `k8s` 却指向了只允许 `compose native` 的 `default` 主机。
- 本地先跑 `scripts/hosts.sh check`，它会指出注册表里缺字段/未知字段的主机。

### `kubeconfig ... 不存在或不可读`

`deploy-k8s.sh` 通过 `ssh host "bash -s"` 执行，**非交互 shell 不会加载 `~/.bash_aliases` 里的
`KUBECONFIG`**；而 k3s 自带的 kubectl 在未指定 kubeconfig 时会去读 root-only 的
`/etc/rancher/k3s/k3s.yaml`，报 permission denied。脚本已显式指向 `~/.kube/config`，主机上按提示准备即可：

```bash
# 在目标 k3s 主机执行
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown "$(id -u):$(id -g)" ~/.kube/config && chmod 600 ~/.kube/config
```

k3s 轮换客户端证书后这份拷贝会失效，重新复制一次即可。

### `ClusterIP 取值异常`

`K8S_HEALTH` 里写的 Service 名在目标命名空间不存在（或 kubectl 返回了错误信息）。
`deploy-k8s.sh` 只接受 IPv4 形式的 ClusterIP，取值异常时会打印诊断信息而不是拼出垃圾 URL。

### rollout 超时

`log` 末尾会打印 `describe`、事件与容器日志尾部。先看 `readinessProbe` 是否一直在失败：

```bash
kubectl -n cops get pods
kubectl -n cops describe deploy/<名字> | tail -30
kubectl -n cops logs deploy/<名字> --tail=50
```

有状态单元（如 `model-logcluster`）探的是 `/readyz`：**属主不对**会让 PVC 写不进去，
表现为 Pod Running 但 readiness 一直不过。见 cloud3.md 迁移 runbook 里的恢复步骤。

### 公网探活失败但集群内正常

- 域名没解析到目标主机，或解析还没生效：`getent hosts <域名>`。
- 证书还没签发完：ACME 需要几十秒，重跑一次部署通常就好了。
- IngressRoute 只写了一条（`[web, websecure]` + `tls`）：Traefik v3 只会生成 websecure 路由器，
  80 端口与 HTTP-01 挑战都会 404。必须拆两条。
