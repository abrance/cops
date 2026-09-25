# cloud3 接入 cops CD 与 model 系列迁移设计

状态：**待实现**（本文是设计稿，实现前请先确认第 9 节「未决项」）

## 1. 背景与目标

`cops` 目前是**单主机** CD：所有部署单元通过同一组 `DEPLOY_HOST` / `DEPLOY_USER` / `DEPLOY_SSH_KEY` secret 发到同一台云主机，由主机上的 `scripts/deploy.sh` 用 `docker compose` 落地。

新主机 cloud3 只装了 k3s（刻意不装 Docker，避免 Docker 的 iptables `FORWARD DROP` 破坏 k3s 的 pod/service 网络），环境情况见 [cloud3.md](cloud3.md)。

目标：

1. 让 cops 支持**多主机**：单元可以声明部署到哪台主机，新增主机不需要改散落各处的判断。
2. 让 cops 支持 **k8s 部署模式**（`DEPLOY_MODE=k8s`），与现有 `compose` / `native` 模式并列。
3. 把 model 系列两个单元（`model-ocr`、`model-logcluster`）迁到 cloud3 的 k3s 上，并从旧主机下线。

## 2. 非目标

- 不改 `scripts/deploy.sh` 的 compose / native 路径行为。
- 不动现有 `DEPLOY_*` secret（默认主机在生产使用中）。
- 不迁 `lems` / `ptdoc` / `vectorman` / `environment/ptdoc-qdrant`。
- 不改 modelman 源码仓库，不重建镜像。
- 不做鉴权（model 系列的 `AUTH_TOKEN` 维持不启用口径，与 modelman 设计 D15/D16 一致）。
- 不引入 Helm / Kustomize / ArgoCD，k8s 侧只用 `kubectl apply`（为什么不用 Helm，见第 10 节决策记录）
- 不做 HPA / PDB / NetworkPolicy（单节点，YAGNI）。

## 3. 现状约束（实测，非假设）

| 约束 | 实测结果 | 影响 |
| --- | --- | --- |
| 镜像源 | cloud3 访问 `ghcr.chenby.cn` → Cloudflare 403（该 mirror 大概只对旧主机 IP 放行）；`ghcr.io` 匿名拉 `abrance/modelman-ocr:v0.1.3-6476ffb`、`abrance/modelman-logcluster:v0.1.1-4c4f4e1` 均为 200 | k8s 单元镜像直接写 `ghcr.io`，不需要凭据、不需要 imagePullSecret、不需要 mirror |
| 公网入口 | cloud3 的 80/443 已由 k3s 自带 Traefik 接管，证书由 Traefik 内置 ACME 自动签发（见 cloud3.md） | 单元入口用 IngressRoute，不需要自建反代 |
| 跨主机互访 | `apps/lems/.env` 里 `OCR_BASE_URL=http://model-ocr:8080`，靠旧主机的 `cops-shared` Docker 网络直连容器名 | model-ocr 搬到 cloud3 后 lems 走不了内网，必须改指向公网入口 |
| k3s 侧凭据 | cloud3 上 `xiaoy` 已有可用的 `~/.kube/config` | CI 复用 SSH 通道执行，kubeconfig 不必进 GitHub Secrets |
| ClusterIP 可达性 | 从 cloud3 主机 `curl http://<Service ClusterIP>/` → 200 | 健康探活可以直接从主机打 Service，不需要进 Pod 或起临时容器 |

## 4. 设计

### 4.1 主机注册表 `hosts.yaml`（仓库根）

```yaml
# 部署目标主机注册表。单元在 app.conf 里用 DEPLOY_TARGET 引用这里的键；不写表示 default。
hosts:
  default:
    drivers: compose native      # 旧主机上 compose 与 native 并存，所以是列表
    notes: 现有云主机，compose / native 单元的默认目标
    secrets:
      host: DEPLOY_HOST
      user: DEPLOY_USER
      key: DEPLOY_SSH_KEY
      port: DEPLOY_PORT
      known_hosts: DEPLOY_KNOWN_HOSTS
  cloud3:
    drivers: k8s
    notes: k3s 单机，环境与人工改动见 docs/cloud3.md
    secrets:
      host: CLOUD3_DEPLOY_HOST
      user: CLOUD3_DEPLOY_USER
      key: CLOUD3_DEPLOY_SSH_KEY
      port: CLOUD3_DEPLOY_PORT
      known_hosts: CLOUD3_DEPLOY_KNOWN_HOSTS
```

规则：

- `secrets` 里存的是 **GitHub Secrets 的名字**，不是值（值只在 workflow 的 `env:` 里映射）。
- 单元的 `DEPLOY_MODE` 必须出现在该 target 的 `drivers` 列表里，否则 PR 阶段直接失败。
  （实现时从单一 `driver` 改成列表：旧主机上 `compose` 与 `native` 并存，单值表达不了。）
- 新增主机 = 加一段 `hosts.yaml` + 建对应 secret + 在 workflow 的 `env:` 加映射，不改其他代码。

### 4.2 GitHub Secrets

| 名称 | 必填 | 说明 |
| --- | --- | --- |
| `CLOUD3_DEPLOY_HOST` | 是 | cloud3 的地址 |
| `CLOUD3_DEPLOY_USER` | 是 | `xiaoy` |
| `CLOUD3_DEPLOY_SSH_KEY` | 是 | **CI 专用私钥**（新生成，不复用个人密钥） |
| `CLOUD3_DEPLOY_PORT` | 否 | `35776`；缺省 22（现有 `default` 主机就没配这个 secret） |
| `CLOUD3_DEPLOY_KNOWN_HOSTS` | 推荐 | cloud3 的主机公钥；缺省时用 `ssh-keyscan` |

主机侧准备（一次性）：把新生成的公钥追加到 cloud3 的 `~/.ssh/authorized_keys`。`xiaoy` 已是 sudo NOPASSWD，k8s 单元不需要提权，所以不需要 `DEPLOY_PASSWORD` 那类 secret。

### 4.3 k8s 单元约定

目录布局与 compose 单元一致，只是把 `compose.yaml` 换成 `k8s.yaml`：

```
apps/<name>/
├── app.conf      # 元数据（新增 k8s 相关字段）
├── .env          # 非敏感变量：镜像 + tag、端口、资源限制、域名
└── k8s.yaml      # 多文档 YAML：Deployment + Service (+ PVC) (+ IngressRoute)
```

`app.conf` 的字段：

```bash
APP_NAME=model-logcluster
DEPLOY_MODE=k8s
DEPLOY_TARGET=cloud3

K8S_NAMESPACE=cops
K8S_ROLLOUT="deployment/model-logcluster"        # 需要等 rollout 的对象，空格分隔
K8S_HEALTH="model-logcluster:8080:/readyz"       # Service:端口:路径，主机侧 curl ClusterIP 探活
PUBLIC_URL="https://logcluster.xiaoyxq.top/readyz"   # 可选：再从公网探一次

HEALTH_TIMEOUT=180
REQUIRED_ENV=""
SECRET_ENV=""
```

`.env` 沿用现有的 `<APP>_*` 命名口径（镜像、tag、端口、资源限制），并新增 `PUBLIC_HOST`：

```bash
MODEL_LOGCLUSTER_IMAGE=ghcr.io/abrance/modelman-logcluster
MODEL_LOGCLUSTER_IMAGE_TAG=v0.1.1-4c4f4e1
MODEL_LOGCLUSTER_PORT=8080
MODEL_LOGCLUSTER_CPU_LIMIT=1.5
MODEL_LOGCLUSTER_MEM_LIMIT=256Mi
PUBLIC_HOST=logcluster.xiaoyxq.top
```

与 compose 版 `.env` 的两处语义变化：

- `_PORT`：原值是**宿主机端口**（9101 / 9103），k8s 里没有这个概念，改指**容器监听的端口**（两个镜像都是 8080），Service 与探针都用它。
- `_MEM_LIMIT`：`256M` / `1500M` 改成 k8s 的 `256Mi` / `1500Mi`（数值不变，单位写法对齐）。

`k8s.yaml` 里用 `${VAR}` 引用这些变量，保持"**回滚 = 改 `.env` 里的 tag**"这一口径不变。示例（含命名空间与共享中间件）：

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ${K8S_NAMESPACE}
---
# 每个单元都声明同一份：apply 幂等，避免依赖单元部署顺序（全量部署不保证顺序）
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: redirect-https
  namespace: ${K8S_NAMESPACE}
spec:
  redirectScheme: {scheme: https, permanent: true}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: model-logcluster
  namespace: ${K8S_NAMESPACE}
spec:
  replicas: 1
  selector: {matchLabels: {app: model-logcluster}}
  template:
    metadata: {labels: {app: model-logcluster}}
    spec:
      containers:
        - name: model-logcluster
          image: ${MODEL_LOGCLUSTER_IMAGE}:${MODEL_LOGCLUSTER_IMAGE_TAG}
          ports: [{containerPort: ${MODEL_LOGCLUSTER_PORT}}]
          env:
            - {name: STATE_DIR, value: /app/state}
            - {name: SIM_TH, value: "${MODEL_LOGCLUSTER_SIM_TH}"}
          readinessProbe:
            httpGet: {path: /readyz, port: ${MODEL_LOGCLUSTER_PORT}}
            initialDelaySeconds: 10
          resources:
            limits: {cpu: "${MODEL_LOGCLUSTER_CPU_LIMIT}", memory: ${MODEL_LOGCLUSTER_MEM_LIMIT}}
          volumeMounts: [{name: state, mountPath: /app/state}]
      volumes:
        - name: state
          persistentVolumeClaim: {claimName: model-logcluster-state}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: model-logcluster-state
  namespace: ${K8S_NAMESPACE}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources: {requests: {storage: 2Gi}}
---
apiVersion: v1
kind: Service
metadata:
  name: model-logcluster
  namespace: ${K8S_NAMESPACE}
spec:
  selector: {app: model-logcluster}
  ports: [{port: ${MODEL_LOGCLUSTER_PORT}, targetPort: ${MODEL_LOGCLUSTER_PORT}}]
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: model-logcluster
  namespace: ${K8S_NAMESPACE}
spec:
  entryPoints: [web]
  routes:
    - match: Host(`${PUBLIC_HOST}`)
      kind: Rule
      middlewares: [{name: redirect-https}]
      services: [{name: model-logcluster, port: ${MODEL_LOGCLUSTER_PORT}}]
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: model-logcluster-tls
  namespace: ${K8S_NAMESPACE}
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`${PUBLIC_HOST}`)
      kind: Rule
      services: [{name: model-logcluster, port: ${MODEL_LOGCLUSTER_PORT}}]
  tls: {certResolver: letsencrypt}
```

注意 IngressRoute **必须拆两条**（web 跳转 / websecure 签证书），原因见 cloud3.md「坑清单」：Traefik v3 里 `[web, websecure] + tls` 只生成 websecure 路由器，80 端口和 HTTP-01 挑战都会 404。

`redirect-https` 中间件属命名空间级对象。**两个单元的 `k8s.yaml` 里都写一份完全相同的**：`kubectl apply` 幂等，这样不依赖单元部署顺序（全量部署不保证顺序，与仓库现有的 `cops-shared` 网络用同一思路）。

### 4.4 CI 改动（`.github/workflows/deploy.yml`）

| job | 改动 |
| --- | --- |
| `resolve` | 每个单元额外输出 `target`（读 `app.conf` 的 `DEPLOY_TARGET`，缺省 `default`）；校验 `hosts.yaml` 存在该 target、且 `DEPLOY_MODE` 与 `driver` 一致；`DEPLOY_MODE=k8s` 时要求存在 `k8s.yaml` |
| `validate` | `DEPLOY_MODE=k8s` 分支：执行 `scripts/render-k8s.py`（渲染即校验，见下方偏离说明）；不做 `docker compose config` |
| `deploy` | `env:` 追加 5 行 `CLOUD3_*` 映射（GitHub 不支持按名动态读 secret，与现有 `DEPLOY_SSH_KEY` 同一套路），再用 `${!var}` 间接取值得到该 target 的连接信息；k8s 单元走「渲染 → 同步 → 执行 `deploy-k8s.sh`」 |

`hosts.yaml` 与 workflow 的 `env:` 之间是**同义重复**（GitHub 限制，值必须静态列在 `env:` 里）。用一步校验兜住：workflow 启动时检查 `hosts.yaml` 里声明的每个 secret 名都在 `env:` 中有映射，缺了立刻失败。

### 4.4.1 实现时的偏离（与设计稿的差异，均已落地）

| 设计稿写的 | 实际实现 | 原因 |
| --- | --- | --- |
| 主机用 `driver` 单值 | `hosts.yaml` 里用 `drivers` 列表 | 旧主机上 `compose` 与 `native` 并存（`vectorman` 就是 native），单值无法表达 |
| `envsubst` 渲染（变量只来自 `.env`） | `scripts/render-k8s.py`（python3 标准库），变量来自 `.env` + `app.conf` | `envsubst` 对未定义变量静默渲染成空串，会把端口/镜像 tag 打成空值；且依赖 `gettext`，runner 上不保证存在。python3 一定有，顺便把"变量必须有定义""不残留 `${...}`""每个文档含 `apiVersion`/`kind`"变成显式失败。同时读 `app.conf` 是为了让 `K8S_NAMESPACE` 这类部署元数据只有一个来源，不必在 `.env` 里重复一份。已知限制：不解析 YAML 结构，所以注释里也不能出现字面量占位符 |
| resolve 逻辑留在 workflow 内联 | 抽到 `scripts/resolve-units.sh`，workflow 只调用 | 可本地复现（脚本头部写了用法），并集中承载 `hosts.yaml` / `DEPLOY_MODE` / `DEPLOY_TARGET` 的一致性校验 |
| 主机注册表解析方式未定 | `scripts/hosts.sh`（awk 严格解析，`check` 子命令做结构校验） | 部署链路不引入 YAML 解析库依赖；结构走样（缩进、字段名写错）变成显式失败而不是静默取空值 |
| 设计稿只在文档里写明"cloud3 用 ghcr.io、旧主机用 ghcr.chenby.cn" | 主机在 `hosts.yaml` 里声明 `registries` 白名单，`scripts/check-registries.sh` 在 PR 阶段强制 | 这条差异写在文档里会被忘掉；模型发布流程只改 tag，但复制旧模板或整行覆盖就会把 registry 换回去，届时是部署时 403 失败（最晚才发现）。改成 PR 阶段硬失败 |
| `K8S_HEALTH` 探活 | 额外校验 ClusterIP 必须是 IPv4 | `kubectl get svc` 输出异常时会拼出垃圾 URL，校验后直接报错并打印诊断 |

### 4.5 `scripts/deploy-k8s.sh`（在 cloud3 上执行）

```
参数：<name> <scope>
1. 读 /opt/cops/<scope>/<name>/app.conf（K8S_NAMESPACE / K8S_ROLLOUT / K8S_HEALTH / PUBLIC_URL / HEALTH_TIMEOUT / REQUIRED_ENV）
2. 检查 REQUIRED_ENV 非空（缺失即失败，不带空值上线）
3. kubectl -n <ns> apply -f /opt/cops/<scope>/<name>/rendered.yaml
4. 对 K8S_ROLLOUT 里每个对象 rollout status --timeout=<HEALTH_TIMEOUT>
5. 取 K8S_HEALTH 的 Service ClusterIP，curl 探活（带重试）
6. 若声明 PUBLIC_URL，再探一次公网地址
7. 任一步失败：打印 kubectl describe 与容器日志尾部后非零退出
```

kubeconfig：用主机上 `xiaoy` 的 `~/.kube/config`，不需要额外传参。

### 4.6 两个单元的期望状态

| 项 | model-ocr | model-logcluster |
| --- | --- | --- |
| 镜像 | `ghcr.io/abrance/modelman-ocr:v0.1.3-6476ffb` | `ghcr.io/abrance/modelman-logcluster:v0.1.1-4c4f4e1` |
| 资源限制 | cpus 2.0 / mem 1500Mi | cpus 1.5 / mem 256Mi |
| 探针 | `httpGet /healthz:8080`，`initialDelaySeconds` 给足模型预热 | `httpGet /readyz:8080`（有状态，不探 `/healthz`，避免"容器健康但业务全 503"的假阳性） |
| 存储 | 无状态 | PVC 2Gi（local-path）挂 `/app/state` |
| 公网入口 | `ocr.xiaoyxq.top` | `logcluster.xiaoyxq.top` |
| 鉴权 | 无 | 无 |

host 端口不再由单元声明：cloud3 上唯一对外入口是 Traefik 的 80/443。

`model-logcluster` v0.1.1 自带 Web 界面：迁到 k8s 后由同一条 IngressRoute 暴露（`/` 即 UI），因此它会是**无鉴权公网可达**的。这与本轮“不考虑安全性”的决定一致，实施时不再额外处理；将来要收口就是 `AUTH_TOKEN` + 只给 IngressRoute 加内网 listener。

### 4.7 调用方改动

`apps/lems/.env`：`OCR_BASE_URL=http://model-ocr:8080` → `https://ocr.xiaoyxq.top`。

其余 `.env` / `app.conf` 不变（`SHARED_NETWORKS` 在 k8s 侧没有对应物，由 Service DNS 取代；lems 不改网络声明，只是不再有同网对端）。

### 4.8 文档更新

| 文件 | 更新内容 |
| --- | --- |
| `README.md` | secrets 表加 `CLOUD3_*`；"已纳管应用"表加「目标主机」列；部署流程补 k8s 模式；目录结构加 `hosts.yaml` 与 `k8s.yaml`；说明镜像源按主机不同 |
| `docs/onboarding.md` | 新增「k8s 单元接入」小节与 `app.conf` 模板 |
| `docs/knowledge.md` | 镜像源按主机区分（已随本设计稿的 PR 完成，见第 6 节） |
| `docs/cloud3.md` | 补「CD 接入」小节：CI 密钥、`hosts.yaml`、k8s 单元部署流程 |
| `docs/troubleshooting.md` | 补 k8s 单元的常见失败：rollout 超时、PVC 属主、证书未签发 |

## 5. 迁移 runbook

前提：cloud3 环境已就绪（见 cloud3.md）；用户已完成 DNS 准备（见下）。

### 第 0 步（人工，用户执行）

1. 生成 CI 专用密钥：本机 `ssh-keygen -t ed25519 -f ~/.ssh/cops-deploy-cloud3 -C cops-ci`
2. 公钥追加到 cloud3：`ssh-copy-id -i ~/.ssh/cops-deploy-cloud3.pub -p 35776 xiaoy@186.244.201.55`
3. 配 5 个 GitHub Secrets（4.2 节）
4. 目标主机上准备部署目录（一次性）：`sudo mkdir -p /opt/cops/secrets && sudo chown -R xiaoy:xiaoy /opt/cops`。
   CI 以部署用户身份写入单元目录与密钥文件，目录不存在或不可写会在同步步骤报 `mkdir: cannot create directory '/opt/cops': Permission denied`（实施时实际踩到）。
5. DNS 加两条 A 记录指向 `186.244.201.55`：`ocr`、`logcluster`；用 `getent hosts` 确认解析生效
   - **顺序要求**：先解析生效，再部署带 IngressRoute 的单元。反了会导致 ACME HTTP-01 挑战 404，撞 Let's Encrypt 限流

### 第 1 步：PR1 — 只加 CD 能力

内容：`hosts.yaml`、`scripts/hosts.sh`、`scripts/resolve-units.sh`、`scripts/render-k8s.py`、`scripts/deploy-k8s.sh`、workflow 改动、4.8 节里与 k8s 模式相关的文档。

合并后行为：默认主机不变，compose 单元不变，**没有任何现网影响**。此时可以手动触发一次全量部署验证旧主机流程未受影响。

### 第 2 步：PR2 — 迁 `model-logcluster`

内容：新增 `k8s.yaml`；`app.conf` 改为 `DEPLOY_MODE=k8s` / `DEPLOY_TARGET=cloud3`；删除 `compose.yaml`。

状态数据搬迁（需要一次停机窗口）：

```bash
# 1) 停旧容器（不要用 -v，会删卷）
ssh <旧主机> 'docker compose -f /opt/cops/apps/model-logcluster/compose.yaml down'

# 2) 导出卷到本机（同时当成备份留着）
ssh <旧主机> 'docker run --rm -v model-logcluster_state:/s busybox:1.36 tar cz -C /s .' \
  > ~/model-logcluster-state-$(date +%F).tgz

# 3) 先让 CI 部署一次（PVC 与 Deployment 一起建），确认 PVC 已 Bound
ssh cloud3 'kubectl -n cops get pvc'

# 4) 缩到 0，保证恢复期间没有写入
ssh cloud3 'kubectl -n cops scale deploy/model-logcluster --replicas=0'

# 5) 灌数据：local-path 的 PV 就是宿主机目录，目录名里带 PVC 名
ssh cloud3 'ls -d /var/lib/rancher/k3s/storage/*model-logcluster-state*'
cat ~/model-logcluster-state-*.tgz | ssh cloud3 \
  'sudo tar xzf - -C /var/lib/rancher/k3s/storage/pvc-<uid>_cops_model-logcluster-state/'

# 6) 属主对齐（以应用进程的 uid:gid 为准）
ssh cloud3 'sudo chown -R <uid>:<gid> /var/lib/rancher/k3s/storage/pvc-<uid>_cops_model-logcluster-state'

# 7) 回正常状态：让 CI 部署或 kubectl -n cops scale deploy/model-logcluster --replicas=1
```

要点：

- **属主不对的表现是“Pod Running、readiness 一直不过、`/readyz` 503”**。`<uid>:<gid>` 实施时先查（`kubectl -n cops exec deploy/model-logcluster -- id`）；不确定时先按镜像默认用户填，再用 `kubectl exec` 验证能否写入。
- PVC 写 2Gi，实施时按旧卷实际大小确认（模板树是增量快照，一般远小于此）。
- 切换期间的写入会丢（停机窗口），接受：模板树会继续累积。
- 旧 tgz 和旧主机上的卷保留到新环境稳定运行一周后再删。

### 第 3 步：PR3 — 迁 `model-ocr`

内容：新增 `k8s.yaml`；`app.conf` 改为 k8s；删除 `compose.yaml`；`apps/lems/.env` 的 `OCR_BASE_URL` 改为 `https://ocr.xiaoyxq.top`。

无状态，不需要搬数据。停机窗口 = lems 切到新地址前后的一小段。

### 第 4 步：旧主机清理（人工）

```bash
ssh <旧主机> 'docker compose -f /opt/cops/apps/model-ocr/compose.yaml down'
ssh <旧主机> 'docker compose -f /opt/cops/apps/model-logcluster/compose.yaml down'
ssh <旧主机> 'rm -rf /opt/cops/apps/model-ocr /opt/cops/apps/model-logcluster'
# 确认新环境稳定后再删卷（先留一份备份）
ssh <旧主机> 'docker volume rm model-logcluster_state'
```

现有流程**没有**"删除旧主机单元"的能力（`--remove-orphans` 只作用于同一 compose 项目内），因此这一步必须手工，也是本 runbook 必须存在的原因。

**容易漏的一条**：旧主机的公网入口由 `dockpanel` 的 traefik（`dockpanel-traefik` 容器）管理，它的路由存在 dockpanel 自己的库里（`dockpanel-postgres`），**不在静态配置里**，所以在 `/etc/dockpanel/traefik/` 下 grep 不到（该目录还是 root-only）。云厂商 DNS 已经把 `ocr` / `logcluster` 指向 cloud3，所以旧路由不会再被命中；但如果面板里确实为这两个服务配过指向 `127.0.0.1:9101` / `127.0.0.1:9103` 的规则，迁移后应删掉或改指 cloud3 的域名，避免留下一条会 502 的入口。实施时确认：旧主机上无 model-\* 容器残留，但面板侧的路由需人工核对。

## 6. 回滚

| 场景 | 动作 |
| --- | --- |
| cloud3 上新版本有问题 | 改 `.env` 里的镜像 tag 回上一个版本（与现有回滚口径一致） |
| 整个迁移要退 | `git revert` 对应 PR → 旧主机 `docker compose up -d`（`compose.yaml` 在 git 历史里，卷没删，数据还在）→ lems 的 `OCR_BASE_URL` 改回 `http://model-ocr:8080` |
| CD 能力本身要退 | `git revert` PR1（`hosts.yaml` + workflow）；单元仍未迁时零影响 |

## 7. 验证清单

- [ ] PR 阶段：`envsubst` 渲染成功、多文档 YAML 可解析、`DEPLOY_TARGET` 在 `hosts.yaml` 中存在、`k8s.yaml` 存在
- [ ] `kubectl -n cops get pods` 两个单元 `Running` 且 `READY 1/1`
- [ ] `curl https://ocr.xiaoyxq.top/healthz` 返回 200，`curl https://logcluster.xiaoyxq.top/readyz` 返回 200
- [ ] `curl -o /dev/null -w '%{http_code} %{ssl_verify_result}'` 对两个域名都是 `200 0`（证书链校验通过）
- [ ] `curl http://<域名>/` 返回 301 且指向 https
- [ ] cloud3 上 `kubectl -n cops rollout status` 通过；`deploy-k8s.sh` 的探活步骤有输出
- [ ] lems 健康检查通过，且日志里能看到对新 OCR 地址的成功调用
- [ ] 旧主机上两个容器已停止、目录已删除、`docker ps` 无残留
- [ ] 全量重建（手动触发 workflow）后状态一致、无需人工干预
- [ ] 旧主机其余单元（lems / ptdoc / vectorman / ptdoc-qdrant）行为未变

## 8. 风险与取舍

| 风险 | 取舍 |
| --- | --- |
| 跨主机调用走公网，无鉴权 | 用户明确「先迁 model 系列，不考虑安全性」。缓解路径：后续加 `AUTH_TOKEN`（modelman 设计 D15/D16 已预留），或两机做 WireGuard 私有互联 |
| `deploy-k8s.sh` 用 `xiaoy` 的 cluster-admin kubeconfig | 与现有 SSH 模式一致，省一个高危 secret；升级路径是专用 ServiceAccount + 受限 RBAC 的 kubeconfig |
| `hosts.yaml` 与 workflow `env:` 同义重复 | GitHub 限制导致，无法消除；用启动时的一致性校验兜住 |
| 渲染在 CI 侧 | 好处是主机不加依赖、错误在 PR 阶段暴露；代价是 PR 校验需要读 `.env`（非敏感，已在仓库里） |
| local-path PVC 是宿主机目录 | 数据搬迁简单，但没有副本、不做快照；单节点本来就没有高可用承诺 |
| 单节点 k3s，扩容/HA 无 | 本次不做多节点；将来加节点时 IngressRoute 与 Service 不用改 |

## 9. 实施前需要拍板的点

1. **`PUBLIC_URL` 探活**：`model-logcluster` 的调用方是用户本人（无自动化），建议保留 `PUBLIC_URL` 并在迁移后手工真实调用一次（不只探 `/readyz`）确认业务可用。默认按"保留"实施。
2. **旧卷保留时长**：默认保留到新环境稳定运行一周后再删（`docker volume rm model-logcluster_state`）。
3. **`AUTH_TOKEN`**：当前决定不加。modelman 设计 D15/D16 已预留，将来要加时改动点是 `app.conf` 的 `SECRET_ENV` + workflow 的密钥映射 + 单元 `.env`。

## 10. 决策记录

### 10.1 为什么自家单元不用 Helm（已否决，勿重复讨论）

**触发背景**：希望 k3s 里的服务与 k3s 生态工具链保持一致，考虑过用 Helm 统一管理。

**决策**：k8s 单元的期望状态用原生清单（`k8s.yaml` + `envsubst` 渲染），**不用 Helm**，也暂不用 Kustomize。

**理由**：统一性分两层，本仓库两层都已经就位：

| 层 | 谁管 | 用什么 |
| --- | --- | --- |
| 消费第三方组件（Traefik、Gateway API CRD、以后的 cert-manager） | k3s 自己（HelmChart 控制器） | 已经就是 Helm，不需要我们写 chart |
| 管理自家服务的期望状态 | cops 仓库 + CI | git 清单（compose / native / k8s.yaml） |

把第一层的工具拿去干第二层的活，收益接近零，代价是真实的：

1. **多一套事实源**：Helm release 状态在集群 Secret 里，而本仓库的回滚口径是“改 `.env` 里的 tag → 合入 main”，git 才是唯一事实源。两套状态并存时，排障先要判断谁赢。
2. **和 k3s 托管的 release 混在一起**：cloud3 上 `traefik` / `traefik-crd` 由 k3s 的 HelmChart 控制器管理（见 [cloud3.md](cloud3.md)），手工 `helm upgrade` 会抢同一份 release。自家 chart 进入同一 Helm 命名空间后，同样要回答“这个 release 谁拥有的”。
3. **多一层模板语言**：`k8s.yaml` 打开就是 k8s 对象；chart 要先 `helm template` 才知道最终渲染成什么，PR 审查与排障都多一步。
4. **与现有 compose 单元不对称**：compose 用 `.env` 做文本插值，不是模板引擎；仓库会变成“compose 靠替换、k8s 靠模板”两种范式并存。

**被否决的替代方案**：

- **HelmChart CR 路线**（把单元做成 chart 放到节点的 `/var/lib/rancher/k3s/server/static/charts/`，再建 `HelmChart` CR 让 k3s 自己 reconcile，自带漂移纠正）。代价：期望状态变成两个控制者（CI 与 k3s 只能留一个）、现有 `HEALTH_URL` 探活与失败诊断要重做、`.env` 改 tag 的路径变长（要重打 chart 包）。**2 个单元规模下不值得。**

**重新评估的触发条件**（出现任意一条再说）：

1. k8s 单元达到 **6 个以上**，且大量同构重复（Deployment + Service + 探针 + IngressRoute 反复抄）→ **先用 Kustomize**（`kubectl` 内置、overlay 范式、零新增依赖），而不是 Helm。

   > 实测提醒（2026-09-25，kubectl v1.33.5 内置的 kustomize）：**不要指望 Kustomize 的结构化校验能拦住写错的 patch**。以下两种写法都是 `exit=0` 静默 no-op，渲染出来的仍是“语法正确”的 YAML，只是改动没生效：
   >
   > - patch 打在不存在的字段路径上（如 `/readinessProbe/httpGet/typo`）
   > - patch 的 target 指向不存在的资源名
   >
   > 这与 `envsubst` 把未定义变量渲染成空串是**同一类坑**，两者都需要仓库侧自己加校验（现有 `k8s.yaml` 方案的对应做法是“检查每个 `${VAR}` 在 `.env` 中有定义”；换成 Kustomize 则要改成“渲染后断言关键字段已生效”）。

   另外实测的体量参考：一套 base（Deployment + Service，34 行）+ 两个 overlay（共 49 行）对两个单元而言与“各写一份 `k8s.yaml`”（约 120 行）**基本打平**，从第三个同构单元开始才净赚。
2. 出现**多环境 / 多主机**需要同一单元不同参数 → Kustomize overlay（`base` + `overlays/<host>`）。
3. 需要把 chart **分发给别人**，或真的需要 chart 依赖管理 → 才考虑 Helm，且只上 `helm template`（渲染） **不**上 `helm install`（release），避免与 git 单一事实源及 k3s 托管的 release 冲突。

### 10.2 为什么不用 `helm install` 即使将来上了 Helm

因为本仓库的模型是“git 是期望状态的唯一事实源、CI 是执行者”。`helm install/upgrade` 会把期望状态的一部分搬到集群内的 release Secret 里，与 git 及 k3s 的 HelmChart 控制器形成第二个事实源。如果要上 Helm，只用 `helm template` 渲染出 YAML，仍然由 `kubectl apply` 落地，回滚仍然是 `git revert`。
