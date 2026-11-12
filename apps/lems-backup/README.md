# lems-backup

ems（`apps/lems`）SQLite 库的定时备份与异地同步。这个单元只做一件事：让「备份体系」
本身也进 git——此前它只存在于 cloud2 的 `/opt/cops/backup/lems-tools-v2/`，
主机重建后编排、Dockerfile、调度全部消失，且没有告警会发现。

## 组成

| 文件 | 作用 |
| --- | --- |
| `compose.yaml` | 常驻容器 `ems-backup`：只读挂生产卷 `lems_lems-data`，写 `/opt/cops/backup/lems` |
| `Dockerfile` | `alpine:3.20` + `sqlite`（`.backup` API）+ `openssh-client`（异地 scp）+ `tini` |
| `backup.sh` | 备份逻辑。**权威副本在 [ems 仓库 `deploy/docker-compose/backup.sh`](https://github.com/abrance/ems/pull/132)**，这里是同步副本 |
| `entrypoint.sh` | 把 `BACKUP_CRON` 写进容器 crond，然后前台跑 `crond` |

## 为什么调度在容器里

cloud2 没有 crond、没有 sudo、user linger 也开不了，宿主机上没有可用的 cron。
所以调度落在常驻容器的 crond 上，每天 03:00（容器 TZ=Asia/Shanghai）。

## 依赖

- 生产卷 `lems_lems-data` 由 `apps/lems` 创建，本单元 `external: true` 只读引用。
- 异地 SSH 私钥与 known_hosts 在宿主机 `/opt/cops/backup/lems-ssh/`（600 / 644），
  只读挂进容器 `/ssh`。**不在 git、也不在 secrets**——它是文件，不是环境变量。
  主机重建后需重新放置（cloud2 → nas 免密）。

## 镜像

本地构建，`image: ems-backup:3` + `pull_policy: build`。没有 registry 可拉，
`pull_policy: build` 让 `deploy.sh` 的 `compose pull` 跳过它（否则会去 docker.io
找一个不存在的同名镜像并失败）。

## 改备份逻辑

1. 改 ems 仓库 `deploy/docker-compose/backup.sh` 并合入。
2. 复制到本目录，一起提 PR。
3. 合入后 CI 同步到主机并 `compose up -d`，镜像随之重建。

不要只改本目录那一份：两份各自演进就失去了「唯一事实源」的意义。

## 验证

```bash
# 容器在跑、crond 活着
docker ps --filter name=ems-backup
docker exec ems-backup pgrep crond

# 备份产物
ls -lt /opt/cops/backup/lems/db-*.sqlite3.gz | head -3
cat /opt/cops/backup/lems/.last-backup

# 手工触发一次（不等 03:00）
docker exec ems-backup /usr/local/bin/backup.sh

# 容器内日志（cron 输出重定向到 /var/log/lems-backup.log）
docker exec ems-backup tail -n 30 /var/log/lems-backup.log
```

恢复不在本单元范围：`restore.sh` 属于人工操作，见 ems 仓库
`deploy/docker-compose/README.md` 的「恢复」一节（生产必须显式 `--yes`）。
