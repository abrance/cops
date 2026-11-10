---
title: Vikunja 卸载存档（2026-11-10）
description: vikunja 服务下线前的迁移、日常改动、备份恢复记录，仅供追溯，不代表当前存在
aliases: vikunja 存档, vikunja 迁移, vikunja 备份
---

# Vikunja 卸载存档（2026-11-10）

服务已于 2026-11-10 按用户决定彻底卸载，**当前集群里不存在**。以下为下线前的原始记录，
仅作追溯；命令中的命名空间、库名、bucket 均已不存在，直接照抄会失败。

下线时的备份在 cloud3 的 `/opt/cops/backup/vikunja-removed-20261110/`：
`vikunja.sql`（42 张表）、`minio-vikunja.tar`、`resources.yaml`、`manifests/`、`vikunja.env`。

### MySQL 与 vikunja 特化：从 `vikunja/` 的手工部署迁入 `environment/mysql8` 与 `apps/vikunja`

迁移前 vikunja 与它的数据库都是手工部署的：ns `vikunja`、StatefulSet `mysql` + PVC
`data-mysql-0`（2Gi local-path）、Secret `vikunja-secret`（DB 口令 / session 密钥 / S3 AK/SK）。
纳入 cops 后变成两个单元：

| 单元 | 命名空间 | 存储 | 说明 |
| --- | --- | --- | --- |
| `environment/mysql8` | `mysql8` | hostPath `/opt/mysql8/data` | **通用** MySQL 8，只跑 root 账号，库与账号由使用方创建；Service 名仍是 `mysql` |
| `apps/vikunja` | `vikunja` | 无（无状态） | ConfigMap + Deployment + Service + 2×IngressRoute；附件在 `minio/` |

**顺序陷阱（必须先看）**：CI 解析单元时 `apps/` 排在 `environment/` 之前。若直接合并 PR
让 CI 一次性部署，vikunja 会先被滚动到新的 DB 地址，而那时 mysql8 要么还没起来、要么是空库——
vikunja 启动会自动跑 migration，把空库建成新 schema，之后导入 dump 必然冲突。
所以先手工起 mysql8 并导数据，再让 CI 切 vikunja 的连接串：

1. 手工建 mysql8（等价于 CI 会做的事，后续 CI apply 幂等）：

   ```bash
   export KUBECONFIG=$HOME/.kube/config
   cd /tmp && python3 -c '
   import re
   docs=[d for d in re.split(r"(?m)^---[ \t]*$", open("rendered.yaml").read()) if d.strip()]
   kinds={"Namespace","StatefulSet","Service"}
   sel=[d for d in docs if re.search(r"(?m)^kind: (\\S+)", d).group(1) in kinds]
   open("mysql8.yaml","w").write("---\\n"+"\\n---\\n".join(sel))'
   # Secret 按部署脚本的规则手工建一次（值取现有 vikunja 的 DB 口令，不落盘）
   kubectl -n mysql8 create secret generic mysql8-secrets \
     --from-literal=MYSQL_ROOT_PASSWORD="$DB_PASSWORD" --dry-run=client -o yaml | kubectl apply -f -
   kubectl apply -f mysql8.yaml
   kubectl -n mysql8 rollout status statefulset/mysql --timeout=300s
   ```

2. 冻结写入：`kubectl -n vikunja scale deploy/vikunja --replicas=0`
3. 导旧库（沿用迁移到 cloud3 时验证过的手法）：

   ```bash
   kubectl -n vikunja exec mysql-0 -- mysqldump -uroot -p"$OLD_ROOT_PW" \
     --single-transaction --routines --triggers --default-character-set=utf8mb4 vikunja > vikunja.sql
   ```

4. 在 mysql8 里建库建号（通用单元不预建任何库），再导入：

   ```bash
   kubectl -n mysql8 exec -i mysql-0 -- mysql -uroot -p"$DB_PASSWORD" <<'SQL'
   CREATE DATABASE IF NOT EXISTS vikunja CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
   CREATE USER IF NOT EXISTS 'vikunja'@'%' IDENTIFIED BY '<与 SECRET_ENV 里 VIKUNJA_DATABASE_PASSWORD 同值>';
   GRANT ALL PRIVILEGES ON vikunja.* TO 'vikunja'@'%'; FLUSH PRIVILEGES;
   SQL
   kubectl -n mysql8 exec -i mysql-0 -- mysql -uroot -p"$DB_PASSWORD" vikunja < vikunja.sql
   ```

5. 校验：`users` / `projects` / `tasks` / `files` / `labels` 等表行数与旧库逐张对齐，中文取
   `hex(title)` 比对，口令哈希聚合值比对（老用户密码必须还能登录）。
6. 合并 PR2 → CI 同时 apply 两个单元：mysql8 是幂等 apply，vikunja 切到
   `mysql.mysql8.svc.cluster.local:3306` 与 `http://minio.minio.svc.cluster.local:9000`。
7. 验收：`/api/v1/info` 返回 v2.7.0、老账号可登录、附件可下载（对象 key 是 `files/<附件 id>`）、
   `deploy-k8s.sh` 的两道探活均通过。
8. 留证后再删旧资源：`mysqldump` 的 SQL、对象清单（`mc ls -r`）、旧 PVC 快照，存云主机
   `~/vikunja-backup-<日期>/`；确认后才 `kubectl -n vikunja delete sts mysql`（PVC 需显式删）、
   `kubectl delete ns minio-test`。

两点与 MinIO 一致的口径：

- **凭据只存在 GitHub Secrets 里**（`COMMON_SIMPLE_PASSWORD` 与仓库 variable `COMMON_ADMIN_USERNAME`）。
  删掉旧 ns 后本地的 `vikunja-secret` / `minio-secret` 一起消失，凭据若不入库就找不回来了。
- 本次迁移**不动行为配置**：`VIKUNJA_SERVICE_ENABLEREGISTRATION` 保持 `true`（公网实例建议改 false，
  但要单独一件事做），DNS 不动，镜像 tag 不动。

### Vikunja 特化：日常改动与升级

- 配置改 `apps/vikunja/k8s.yaml` 的 ConfigMap（非敏感）或 GitHub Secrets（DB 口令 / session 密钥 /
  S3 凭据）；`deploy-k8s.sh` 会把 ConfigMap 与 Secret 的内容哈希写进 podTemplate 注解，
  内容变才滚动，幂等。改了 `VIKUNJA_SERVICE_SECRET` 会让所有已登录 session 失效。
- 升级镜像：改 `apps/vikunja/.env` 的 `VIKUNJA_IMAGE_TAG` 后合并。启动时会自动跑 DB migration，
  **migration 不可回退**：回滚镜像不会回滚 schema，跨大版本升级前先留一份 `mysqldump`。
- 附件：对象 key 带 `files/` 前缀（`files.basepath`），手工往 MinIO 里放对象时必须带前缀，
  否则附件 404 且 `vikunja doctor` 也不会报错。
- 自带 MCP server 在 `/api/v2/mcp`（streamable HTTP），AI 客户端用它建单/查单；
  长期 token 在 vikunja 的「设置 → API Tokens」里签发，**不要**写进本仓库。

### Vikunja 备份与恢复

**现状（重要）**：`vikunja` 的数据只有在线副本——MySQL 在宿主机的 `/opt/mysql8/data`，附件在
`/opt/minio/data`，两边的旧 PVC 都已删。任何一份挂了都只能靠下面的备份重建。

| 产物 | 位置 | 说明 |
| --- | --- | --- |
| 数据库基线 | `/opt/cops/backup/vikunja-2026-10-15/vikunja-2.7.0-20261015.sql`（md5 `c86d23a94d92285fa13d8de9970a4659`） | 2026-10-15 迁移后立即导的逻辑备份，已做过一次恢复演练 |
| 对象清单 | 同目录 `minio-objects-20261015.json` | `mc ls --recursive --json` 全量清单 |
| 集群快照 | 同目录 `cluster-snapshot-20261015.txt`、`hostpath-du-20261015.txt` | 三个 ns 的对象列表与 hostPath 占用 |

更早的备份（云主机 `~/vikunja-backup/vikunja-2.2.2-20261013.sql`，2026-10-13 从本机迁到
cloud3 时留的）已按 2026-10-15 的决定清理，本目录这现在是**唯一一份库备份**，
未建每日 dump 前请勿删除。

导一份新的基线（在 cloud3 上执行）：

```bash
export KUBECONFIG=$HOME/.kube/config
D=/opt/cops/backup/vikunja-$(date +%F); mkdir -p "$D"
kubectl -n mysql8 exec mysql-0 -c mysql -- sh -c \
  'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --triggers \
     --default-character-set=utf8mb4 vikunja' > "$D/vikunja-$(date +%F).sql"
md5sum "$D"/*.sql
kubectl -n minio exec minio-0 -c minio -- sh -c \
  'mc alias set chk http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null && \
   mc ls --recursive --json chk' > "$D/minio-objects-$(date +%F).json"
```

**导完必做恢复演练**（不然等于没备份）——导到临时库比行数，比对完立即删：

```bash
kubectl -n mysql8 exec mysql-0 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
  -e "drop database if exists vikunja_verify; create database vikunja_verify character set utf8mb4 collate utf8mb4_unicode_ci;"'
kubectl -n mysql8 exec -i mysql-0 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" vikunja_verify' < "$D/vikunja-$(date +%F).sql"
# 逐张表 COUNT(*) 对齐后：
kubectl -n mysql8 exec mysql-0 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "drop database vikunja_verify;"'
```

恢复口径：MySQL 用 dump 建库建号再导入（`vikunja` 库、`vikunja@%` 账号）；附件把对象放回
`/opt/minio/data/<bucket>/<key>`（注意对象 key 带 `files/` 前缀）；vikunja 本身无状态，
`kubectl -n vikunja rollout restart deploy/vikunja` 即可。

**mysql8 的账号口径**：`root@%`（CI 下发的 `MYSQL_ROOT_PASSWORD`）、`xiaoy@%`（2026-10-15 建的
管理账号，口令与 root 同值，对应 `COMMON_ADMIN_USERNAME`）、以及各应用自己的账号
（如 `vikunja@%`）。通用单元不预建任何库，新应用接入时自行建库建号。
