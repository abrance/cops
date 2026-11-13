# `apps/pg` 回滚（一条命令）

## 场景 A：llmbm 要退回旧实例（数据在 `pg-test`，仍在运行、只读封存）

```sh
kubectl -n cops create secret generic llmbm-pg \
  --from-literal=LLMBM_PG_URL="postgres://llmbm:<口令>@pg.pg-test.svc.cluster.local:5432/llmbm" \
  --dry-run=client -o yaml | kubectl apply -f - && \
kubectl -n cops rollout restart deploy/llmbm && kubectl -n cops rollout status deploy/llmbm
```

口令**必须现取，不能从旧记录/旧会话里拷**：

```sh
kubectl -n pg-test get secret pg-secret -o jsonpath='{.data.LLMBM_DB_PASSWORD}' | base64 -d
```

（注意是 `LLMBM_DB_PASSWORD`，不是 `POSTGRES_PASSWORD`——后者是超级用户 `xiaoy` 的，
拿它当 `llmbm` 的口令会直接 authentication failed。）

**2026-11-13 已轮换**：`pg-test` 的 `llmbm` 角色口令被破包成 base64 落进过别人的会话记录，
已用 `ALTER ROLE llmbm PASSWORD` 换成新的 32 位随机值，同步写回 `pg-test/pg-secret` 的
`LLMBM_DB_PASSWORD`（实测：新口令能连、旧口令 `b383f7c1…` 已 `password authentication failed`）。
所以**任何文档、会话记录、截图里的旧口令都不能当回滚目标**，一律走上面这条命令现取。
也注意 `pg-test` 的 `pg_hba.conf` 对 `127.0.0.1` 与 local 是 `trust`（旧实例遗留，实测乱口令也能连上），
所以在 `pg-test` Pod 内部自测口令没有意义，要从别的 Pod 经 Service 连才算数。

## 场景 B：要恢复公网 30630（只有明确需要时才做，等于重新打开那个洞）

```sh
kubectl -n kube-system patch helmchartconfig traefik --type=merge \
 -p '{"spec":{"valuesContent":"additionalArguments:\n  - \"--certificatesresolvers.letsencrypt.acme.email=1103098607@qq.com\"\n  - \"--certificatesresolvers.letsencrypt.acme.storage=/data/acme.json\"\n  - \"--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web\"\n  - \"--entrypoints.pg.address=:5432\"\n  - \"--entrypoints.mysql.address=:3306\"\nports:\n  pg:\n    port: 5432\n    expose:\n      default: true\n    exposedPort: 5432\n    protocol: TCP\n  mysql:\n    port: 3306\n    expose:\n      default: true\n    exposedPort: 3306\n    protocol: TCP\npersistence:\n  enabled: true\n  size: 128Mi\n"}}'
```

改动前的原始 valuesContent 存档：`cloud3:/opt/cops/backup/traefik-config/valuesContent-before-pg-removal-20261113.yaml`。

## 场景 C：整个 `apps/pg` 单元撤掉

```sh
cd /opt/mystorage/github/cops && git revert --no-edit <apps/pg 的合并提交> && git push origin main
kubectl delete ns pg   # 或保留：--dry-run 先看会删什么
```

`kubectl delete ns pg` 会连带删掉 PVC `data-pg-0`（local-path 的 reclaimPolicy 是 Delete，
HostPath 数据也要手工清 `/var/lib/rancher/k3s/storage/pvc-5fe66e2b-*`）。**删之前先确认 MinIO
里 `pg-backup` bucket 的 dump 可用**，否则数据不可恢复。

## 存量归档

- `pg-backup` bucket 的 `archive/litellm-20261113.dump`：旧 `pg-test` 实例里 `litellm` 库
  （13 MB，已无服务在用）的完整 `pg_dump -Fc` 归档，**不迁**进新实例。需要时可以
  恢复到一个临时库再取数：
  ```sh
  kubectl -n pg run pg-restore --rm -it --restart=Never \
    --image=docker.io/library/postgres:17 -- bash
  # 容器内：pg_restore -h pg.pg.svc.cluster.local -U xiaoy -d <临时库> /path/litellm.dump
  ```
  sha256：`3b0b1dc86c30c1ceba9be725546c8fee0ddeaec435871e30a81f091541f177c9`（原始 292087 字节）。

## 备份在哪、能扛什么

| 落点 | 位置 | 保留 | 与 PG 数据是否同一失效域 |
|---|---|---|---|
| MinIO | `pg-backup` bucket 的 `daily/`（对象存储服务端；数据目录是 cloud3 hostPath `/opt/minio/data`） | 14 天 | **是**：同在本机 `/dev/vda1` |
| 宿主机目录 | `cloud3:/opt/cops/backup/pg`（每周日那份） | 4 周 | **是**：同一块盘 |
| 异地 | `xiaoy@10.193.0.5:/pool1_8t/public/backup/pg`（NAS，另一台物理机） | 14 份 | **否**，唯一真异地副本 |

前两处只能扛「误删库 / 误删 PVC / 重建命名空间」；盘坏或 cloud3 整体丢失时只剩 NAS 那份。
每天 03:00 的 Job 会把 dump 传到 NAS 并回读 sha256，不一致即 Job 失败（不会静默只留本地）。

**NAS 侧权限是手工操作，不在 GitOps 里**：`/pool1_8t/public/backup/pg` 的 `700` 与文件 `600` 是
2026-11-13 手工设的（此前 `775/644`，NAS 上任意本地用户可读，而 `pg-globals-*.sql` 带 SCRAM 口令校验子）。
换盘、重装 NAS 或恢复 `/pool1_8t` 之后权限会回到默认值，**恢复完必须先重设再让 cron 继续跑**：

```sh
ssh xiaoy@10.193.0.5 'chmod 700 /pool1_8t/public/backup/pg && chmod 600 /pool1_8t/public/backup/pg/*'
```

**恢复演练（2026-11-13 实测，唯一一次）**：把 NAS 上的 `pg-llmbm-20261113.dump` 拉回 cloud3，
`pg_restore` 进临时库 `llmbm_drill`（`-U xiaoy` 超级用户，注意本实例没有 `postgres` 角色、
连库必须显式 `-d postgres`），比对 `results` 表：行数 1/1、全表内容 md5 与线上逐位一致，演练后已删临时库。
定期重跑这条：**没演练过的 dump 等于没有 dump**（见 [best-practices](best-practices.md)）。
