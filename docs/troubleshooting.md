# 排障手册

先定位失败发生在哪一步，再对症处理。流水线各步骤对应如下。

```text
解析待部署应用 → 校验 <服务> → 校验部署凭据 → 配置 SSH 主机密钥
→ 同步应用文件 → 下发运行期密钥 → 执行部署
                                        ├─ 拉取镜像
                                        ├─ 应用期望状态
                                        ├─ 等待容器健康
                                        └─ 探测健康接口
```

## 快速定位

| 现象 | 先看 |
| --- | --- |
| 某个 job 红 | Actions 里展开该 job 的失败步骤 |
| 「部署 <服务>」红 | 该 job 的「执行部署」步骤输出，会打印容器日志尾部 |
| 服务不可访问但部署绿 | 云主机上 `docker compose ... ps` 与 `docker logs` |
| 只想重新部署一次 | Actions → Deploy → Run workflow，`app` 填服务名 |

## 部署失败

### 缺少 GitHub Actions secret

```text
缺少 GitHub Actions secret: DEPLOY_HOST DEPLOY_USER SSHPASS
```

SSH 部署凭据缺失。到 `Settings → Secrets and variables → Actions` 配置。这四个是仓库级必备：

| 名称 | 说明 |
| --- | --- |
| `DEPLOY_HOST` | 云主机地址 |
| `DEPLOY_USER` | SSH 用户 |
| `DEPLOY_PASSWORD` | SSH 密码 |
| `DEPLOY_KNOWN_HOSTS` | 主机公钥（可选，建议固定） |

若报的是你自己的业务密钥（如 `MYAPP_API_KEY`），说明「下发运行期密钥」步骤里没有该变量：检查 `app.conf` 的 `SECRET_ENV` 与 `deploy.yml` 的 `env:` 两处是否都写了。

### 缺少必需变量

```text
==> [<服务>] 缺少必需变量 MYAPP_API_KEY，请写入 /opt/cops/secrets/<服务>.env
```

这是 `REQUIRED_ENV` 的兜底检查，说明密钥没有进到云主机。原因通常是上一条：secret 未配置或未在 `deploy.yml` 声明。修正后重新部署即可；无需手工在服务器创建文件（会被 CI 覆盖）。

### 校验编排文件失败

本地用同一命令复现：

```bash
docker compose --project-directory apps/<服务> -f apps/<服务>/compose.yaml config
```

常见原因：YAML 缩进错误、变量名拼写不一致、`volumes:` 顶层未声明命名卷。

### SSH 主机密钥校验失败

报 `Host key verification failed`。若配置了 `DEPLOY_KNOWN_HOSTS`，确认其内容与云主机当前公钥一致（主机重装后会变化）。获取方式：

```bash
ssh-keyscan -t ed25519,rsa <云主机地址>
```

### 拉取镜像失败

报 `manifest unknown` 或 `denied`。检查：

- 镜像是否已发布到 `ghcr.chenby.cn/abrance/<服务>`，tag 是否存在于远程。
- 镜像源是否可被目标主机访问；当前仓库不保存 registry 凭据。

在云主机上直接验证：

```bash
docker pull ghcr.chenby.cn/abrance/<服务>:vX.Y.Z
```

## 容器 unhealthy

### 查看状态与日志

```bash
docker compose -f /opt/cops/apps/<服务>/compose.yaml ps
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

Actions → Deploy → Run workflow → `app` 填服务名。因为 `pull_policy: always`，同 tag 也会重新拉取镜像。

**回滚**：

1. 把 `apps/<服务>/.env` 的镜像 tag 改回上一个 `vX.Y.Z`。
2. 开 PR 合入 `main`。

紧急情况下可先在云主机临时处理，但必须随后回补到仓库，否则下次部署或定时纠偏会覆盖。

## 常见问答

**为什么我改了 docs 但什么也没跑？**

流水线只在 `apps/**`、`scripts/**`、workflow 自身变更时触发。仅文档变更不会有 run。

**为什么 PR 里没有部署？**

设计如此：PR 只跑编排校验，合入 `main` 才部署。

**为什么我只改了一个服务，却部署了全部？**

你改动了 `scripts/**` 或 workflow 本身，这被判定为部署逻辑变更，会全量部署。

**为什么我手工改的服务器文件消失了？**

`/opt/cops/apps/<服务>` 每次部署由 CI 全量覆盖。所有变更请回仓库。

**为什么容器没重建？**

期望状态与线上一致（幂等）。需要强制重建用 `workflow_dispatch`，或改一个会改变容器定义的值。
