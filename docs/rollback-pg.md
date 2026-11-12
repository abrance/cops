# `apps/pg` 回滚（一条命令）

## 场景 A：llmbm 要退回旧实例（数据在 `pg-test`，仍在运行、只读封存）

```sh
kubectl -n cops create secret generic llmbm-pg \
  --from-literal=LLMBM_PG_URL="postgres://llmbm:<旧口令>@pg.pg-test.svc.cluster.local:5432/llmbm" \
  --dry-run=client -o yaml | kubectl apply -f - && \
kubectl -n cops rollout restart deploy/llmbm && kubectl -n cops rollout status deploy/llmbm
```

旧口令在 `pg-test/pg-secret`（`kubectl -n pg-test get secret pg-secret -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d`）
与当时的 `cops/llmbm-pg` 一致。**这条回滚只把 DSN 指回去**，不恢复公网入口——
`pg-test` 不需要再暴露到 30630 也能被 `cops` 命名空间访问（同一个集群）。

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
