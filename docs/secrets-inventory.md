# Secrets 台账（abrance/cops）

本文是仓库运行期密钥的**元数据**台账：变量名、存放位置、长度、权限、轮换方式与验证方法。

**本文不含任何明文值**，只记长度与掩码。取值请直接到对应存放位置读。
台账基线日期：2026-11-13。

## 1. 密钥的三层结构

cops 的密钥不是「存在一处」，而是三层各存一份，职责不同：

| 层 | 位置 | 谁写入 | 谁读 | 说明 |
|---|---|---|---|---|
| L1 GitHub Actions secret | `abrance/cops` 仓库 Secrets（环境 `production`） | 人工 / `gh secret set` | `.github/workflows/deploy.yml` | 只写不读，GitHub 不回显值，因此长度只能由本机镜像或目标端反推 |
| L2 主机 secrets 文件 | cloud3（及旧云主机）`/opt/cops/secrets/<unit>.env` | Deploy 工作流「下发运行期密钥」步骤（stdin 传输，`umask 077`） | `scripts/deploy-k8s.sh` / `deploy.sh` | 每次部署按 `app.conf` 的 `SECRET_ENV` 重写，**主机上手工改会被下次部署覆盖** |
| L3 k8s Secret | cloud3 `cops` 等命名空间（由 `k8s.yaml` 的 `secretRef` 引用） | `deploy-k8s.sh` 从 L2 生成 | Pod 环境变量 | Deployment 靠 `cops.vectorman.cn/secret-checksum` 注解感知变化并滚动 |

关键推论：**轮换只能从 L1 改**。直接改 L2/L3 都会在下一次部署被 L1 重渲染覆盖。

补充：本机 `/home/xiaoy/.github.env` 是 L1 的镜像副本（用户长期约定：GitHub Actions 里有的 secret，本机也留一份），便于本机排障与复用，不属于上面三层。

## 2. 逐变量台账

长度单位为字符数；「主机文件」指 cloud3 `/opt/cops/secrets/` 下的对应文件，权限详见第 3 节。
「上次轮换」以 GitHub Secrets 的 `updated_at` 为准，该时间即最后一次写入时间。

### 2.1 部署主机凭据（SSH）

| 变量名 | L1 GitHub | L2 主机文件 | L3 k8s | 长度 | 上次写入 (UTC) | 影响面 | 轮换后验证 |
|---|---|---|---|---|---|---|---|
| `DEPLOY_HOST` | ✔ | — | — | 14 | 2026-09-16T02:45:31Z | 旧云主机（compose/native 单元的默认目标） | 部署日志「解析目标主机」步骤打印 host 与连通性 |
| `DEPLOY_USER` | ✔ | — | — | 5 | 2026-09-16T02:48:34Z | 同上 | 同上 |
| `DEPLOY_PORT` | ✔ | — | — | 2 | 2026-09-16T02:49:03Z¹ | 同上 | SSH 连通即通过 |
| `DEPLOY_PASSWORD` | ✔ | — | — | 11 | 2026-09-16T02:49:03Z | **deploy.yml 未引用**（历史遗留，sudo 用途已随 vectorman 迁 k8s 取消） | 无需验证；建议标为待清理 |
| `DEPLOY_SSH_KEY` | ✔ | — | — | 2601（OpenSSH RSA，38 行） | 2026-09-23T12:37:19Z | 旧云主机部署登录；指纹 `SHA256:UuXQdOEY…N72o` | 用该私钥 `ssh` 到 `DEPLOY_HOST` 返回主机名 |
| `DEPLOY_KNOWN_HOSTS` | ✔ | — | — | 95 | 2026-09-16T02:50:53Z | 同上，`StrictHostKeyChecking=yes` 用 | 指纹须等于实测 `ssh-keyscan` 结果 |
| `CLOUD3_DEPLOY_HOST` | ✔ | — | — | 14 | 2026-09-25T12:48:00Z | cloud3（全部 k8s 单元） | 同下 |
| `CLOUD3_DEPLOY_USER` | ✔ | — | — | 5 | 2026-09-25T12:48:01Z | cloud3 | 同下 |
| `CLOUD3_DEPLOY_PORT` | ✔ | — | — | 5 | 2026-09-25T12:48:02Z | cloud3 | 同下 |
| `CLOUD3_DEPLOY_SSH_KEY` | ✔ | — | — | 398（OpenSSH ED25519，7 行） | 2026-11-08T06:25:34Z | cloud3 部署登录；指纹 `SHA256:KkU/7jz3…CDhB8`，注释 `cops-ci-v2` | 该密钥须在 cloud3 `~/.ssh/authorized_keys` 中；实测 `ssh` 返回 `cloud3-16c16g` |
| `CLOUD3_DEPLOY_KNOWN_HOSTS` | ✔ | — | — | 103 | 2026-09-25T12:48:08Z | cloud3，`StrictHostKeyChecking=yes` | 指纹须等于 `ssh-keyscan -p <port>` 的 ED25519 结果 |

¹ `DEPLOY_PORT` 与 `DEPLOY_PASSWORD` 的 `updated_at` 完全相同，说明是同一次批量写入。

### 2.2 lems / lems-cloud3 运行期密钥

`apps/lems-cloud3/app.conf`：
`REQUIRED_ENV="QINIU_ACCESS_KEY QINIU_SECRET_KEY QINIU_BUCKET QINIU_DOMAIN"`
`SECRET_ENV="QINIU_ACCESS_KEY QINIU_SECRET_KEY EMS_API_STATIC_TOKEN"`

| 变量名 | L1 GitHub | L2 `/opt/cops/secrets/lems-cloud3.env` | L3 `cops/lems-cloud3-secrets` | 长度 | 上次写入 (UTC) | 影响面 | 轮换后验证 |
|---|---|---|---|---|---|---|---|
| `QINIU_ACCESS_KEY` | ✔ | ✔ (600) | ✔ | 40 | 2026-09-22T01:53:43Z | 日报图片归档到七牛；**换掉会导致历史图片链接仍可用但新归档失败，需同时改七牛控制台** | 部署后容器内变量长度一致；触发一次 OCR 归档 |
| `QINIU_SECRET_KEY` | ✔ | ✔ (600) | ✔ | 40 | 2026-09-22T01:54:23Z | 同上 | 同上 |
| `EMS_API_STATIC_TOKEN` | ✔ | ✔ (600) | ✔ | 11（**偏短，待轮换为 32**） | 2026-11-08T04:16:47Z | ems 静态 token 鉴权，命中即 admin 全权限（读写均放行） | 见第 5 节四条实测 |

注：`QINIU_BUCKET` / `QINIU_DOMAIN` 在 `REQUIRED_ENV` 但**不在** `SECRET_ENV` —— 它们是明文，写在仓库 `apps/lems-cloud3/.env` 里，不属于密钥。

### 2.3 其他单元的密钥

| 变量名 | L1 GitHub | L2 主机文件 | L3 k8s Secret | 长度 | 上次写入 (UTC) | 引用单元 | 影响面 / 验证 |
|---|---|---|---|---|---|---|---|
| `GSE_AGENT_TOKEN` | ✔ | `vectorman.env` (600) | `vectorman/gse-agent-token`（key `token`）、`vectorman/vectorman-secrets` | 27 | 2026-11-09T06:41:08Z | `apps/vectorman`（REQUIRED_ENV+SECRET_ENV） | gse-agent DaemonSet 注册；换错则 DaemonSet 注册失败。验证：`gse-agent` Pod 日志无注册报错 |
| `COMMON_SIMPLE_PASSWORD` | ✔ | `pg.env`/`minio.env`/`mysql8.env` (600) | `pg/pg-secrets`、`minio/minio-secrets`、`mysql8/mysql8-secrets` | 11 | 2026-10-14T10:29:53Z | mysql8、minio、pg（经 `MINIO_ROOT_PASSWORD` 映射） | **一个值覆盖三个组件**（有意复用避免漂移）。验证：三者 Pod 均能连自身 DB/MinIO |
| `POSTGRES_PASSWORD` | ✔ | `pg.env` (600) | `pg/pg-secrets` | 48 | 2026-11-12T20:15:53Z | `apps/pg`（REQUIRED_ENV+SECRET_ENV） | Postgres 超级用户；换掉须同步改库内口令 |
| `LLMBM_DB_PASSWORD` | ✔ | `pg.env` (600) | `pg/pg-secrets` | 48 | 2026-11-12T20:15:55Z | `apps/pg`、`apps/llmbm` | llmbm 应用角色口令；注意 `cops/llmbm-pg` 里的 `LLMBM_PG_URL` 含该口令的连接串，轮换须一并重建 |
| `PTDOC_DATA_KEY` | ✔ | `ptdoc.env`（旧云主机，600） | —（compose 单元） | 11 | 2026-09-16T03:19:19Z | `apps/ptdoc`（REQUIRED_ENV+SECRET_ENV） | ptdoc 数据加密 key；换掉会导致既有数据无法解密，**非必要不轮换** |
| `MODEL_TOKEN` | ✔ | `model-jev.env` (600) | `cops/model-jev-secrets`（key `AUTH_TOKEN`） | 11 | 2026-09-30T15:45:01Z | `apps/model-jev` | 公网 Bearer token，**名称映射**：secret 名 `MODEL_TOKEN` → 容器侧 `AUTH_TOKEN`。换掉须同步改调用方 pi-jev 的 `TYPESAFE_API_KEY` |
| `AGENT_PROVIDER_API_KEY` | ✔ | `model-agent.env`、`omp-web.env` (600) | `cops/model-agent-secrets`、`cops/omp-web-secrets` | 17 | 2026-10-01T10:33:20Z | `model-ocr`/`omp-web` | 上游模型供应商 key；换掉影响 OCR 与 omp-web 的模型调用 |
| `PI_WEB_PASSWORD` | ✔ | `model-agent.env` (600) | `cops/model-agent-secrets` | 11 | 2026-09-27T16:08:40Z | model-agent | Web 面板口令 |
| `VECTORMAN_AGENT_TOKEN` | ✔ | — | — | 11 | 2026-09-26T01:12:41Z | **deploy.yml 已不引用**（vectorman 迁 k8s 后由 `GSE_AGENT_TOKEN` 取代） | 建议标为待清理 |

补充说明：
- L3 中 `cops/llmbm-pg` 的 `LLMBM_PG_URL`（长度 100）是**派生值**（连接串内嵌口令），由 `pg` 单元部署时生成，不是独立 secret 来源。
- `pg-test` 命名空间是旧测试实例，其 `pg-secret` 已被 `pg/pg-secrets` 取代，属待清理对象。

## 3. 主机文件权限（cloud3 `/opt/cops/secrets/`）

目录 `drwxr-xr-x xiaoy:xiaoy`，文件全部 `600 xiaoy:xiaoy`（`deploy.yml` 用 `umask 077` + `chmod 600` 保证）：

| 文件 | 权限 | 变量 | 长度 |
|---|---|---|---|
| `lems-cloud3.env` | 600 | QINIU_ACCESS_KEY / QINIU_SECRET_KEY / EMS_API_STATIC_TOKEN | 40 / 40 / 11 |
| `pg.env` | 600 | POSTGRES_PASSWORD / LLMBM_DB_PASSWORD / MINIO_ROOT_USER / MINIO_ROOT_PASSWORD | 48 / 48 / 5 / 11 |
| `vectorman.env` | 600 | GSE_AGENT_TOKEN | 27 |
| `model-agent.env` | 600 | AGENT_PROVIDER_API_KEY / PI_WEB_PASSWORD | 17 / 11 |
| `model-jev.env` | 600 | AUTH_TOKEN | 11 |
| `mysql8.env` | 600 | MYSQL_ROOT_PASSWORD | 11 |
| `minio.env` | 600 | MINIO_ROOT_USER / MINIO_ROOT_PASSWORD | 5 / 11 |
| `omp-web.env` | 600 | AGENT_PROVIDER_API_KEY / OMP_WEB_PASSWORD | 17 / 11 |
| `openbao.env` | 600 | OpenBao unseal keys / root token（JSON） | 见文件 |

`openbao.env` 是唯一的例外形态：内容是 JSON（`unseal_keys_b64`/`unseal_keys_hex`/`root_token`），不是 `KEY=VALUE`，因此不参与 `SECRET_ENV` 分发，由 OpenBao 单元单独使用。**该 root token 与 unseal keys 是集群级高危凭据，泄露等同于接管全部 secrets。**

## 4. 轮换方式（标准流程）

1. 生成新值（`openssl rand -hex 16` 或 `head -c 32 /dev/urandom | base64`）。
2. 写入 L1：`gh secret set <NAME> -R abrance/cops --env production`（或按仓库当前约定不带 `--env`）。
3. 同步本机镜像：更新 `/home/xiaoy/.github.env` 同名项（权限保持 600；多行值必须整段加引号，见第 6 节）。
4. 触发部署：改对应单元的 `apps/<unit>/.env` 触发路径（如升 tag）或 `workflow_dispatch` 指定 `app`，让 Deploy 重渲染。
5. 等待 `secret-checksum` 变化 → Deployment 自动滚动（**不要手工 `kubectl edit secret`，下次部署会被覆盖**）。
6. 按第 2 节「轮换后验证」逐条实测。
7. 在本文更新「上次写入」列。

不需要一并滚动的对象：`apps/lems-cloud3/app.conf` 的 `K8S_ROLLOUT` 同时列了 `deployment/emsdevice` 与 `deployment/lems`，但 `deploy-k8s.sh` 只给**真正引用该 Secret** 的工作负载打 checksum 注解。emsdevice 只挂 `emsdevice-config`（ConfigMap），不引用 `lems-cloud3-secrets`，因此密钥轮换不会让它重启。

## 5. `EMS_API_STATIC_TOKEN` 现状与轮换计划

- 当前长度 11，命中即 admin 全权限（读写都放行）。
- 已确认可从 `POST /api/spot-report/extract` 等写接口通过鉴权 → 风险偏高。
- 计划：轮换为 32 位随机值，走第 4 节流程，并按下列四条验收：
  1. 旧 token → `code:401`
  2. 新 token 打 `/api/spot-report` → `code:0`
  3. 新 token 打写接口（`POST /api/spot-report/extract` 不带参数）→ 返回参数校验错误，**不是** 401
  4. `/api/health` 全绿
  5. 附加：`emsdevice` Pod 的 `creationTimestamp` 与重启计数不变

状态：**待执行**（见 PR 描述中的当前进度）。

## 6. 本机镜像文件 `/home/xiaoy/.github.env` 的约定

- 权限 `600`，属主 `xiaoy:xiaoy`。
- 覆盖范围：cops 侧全部 24 个 Actions secret（本机另有 `DEPLOY_PASSWORD` / `VECTORMAN_AGENT_TOKEN` 两个历史遗留项，GitHub 侧已不被引用）。
- **多行值必须整段用双引号包裹**：私钥、`known_hosts` 这类多行值若不加引号直接粘贴，`source` 时会被当成多条命令执行，值读出来是空或截断（本次修复前 `CLOUD3_DEPLOY_SSH_KEY` 长度为 0，两份私钥的 base64 正文被当作键名解析）。
- 校验方式：`set -a; . ~/.github.env; printf %s "${#KEY}"` 比对长度；私钥再用 `ssh-keygen -lf` 比对指纹。

## 7. 明文外泄排查结论（2026-11-13）

扫描对象与结果：

| 范围 | 方法 | 结论 |
|---|---|---|
| cops 仓库全部 tracked 文件 | 用 24 个密钥值做字面量匹配 | 仅命中 `postgres` 这个**数据库名**（非密钥值，属误报） |
| cops 仓库 git 全历史 | `git log -S <value> --all` 逐个密钥值 | 无命中 |
| ems 仓库 tracked 文件 + 全历史 | 同上 | 无命中 |
| ems 前端产物 `OpenLEMS/web/dist`（86 文件 / 1.1 MB） | 字面量匹配 | 无命中 |
| cloud3 全盘（`/opt/cops`、`/home/xiaoy`、`/etc/netdata`，≤2 MB 文本） | 字面量匹配 + 权限检查 | 只在 `600` 的 `/opt/cops/secrets/*.env` 内出现，无世界可读副本 |

结论：**未发现明文泄露**。唯一需要关注的是 `openbao.env` 内含集群级 root token，已 `600` 且不在任何仓库中。

---

维护约定：新增部署单元时，同步更新第 2 节的表格与 `app.conf` 的 `SECRET_ENV`；新增主机时更新 2.1 节与 `hosts.yaml`。
