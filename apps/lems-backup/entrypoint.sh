#!/bin/sh
# ems-backup 容器的入口：容器里只有 crond，把 backup.sh 写成定时任务后前台跑。
# 备份逻辑本身在 backup.sh（权威副本在 ems 仓库 deploy/docker-compose/backup.sh，
# 本单元 apps/lems-backup/backup.sh 是同步过来的副本），这里只负责调度。
set -eu
: "${BACKUP_CRON:=0 3 * * *}"
# 只读挂进容器的生产卷固定是 /src，备份目录是 /dst，与脚本默认一致
echo "${BACKUP_CRON} /usr/local/bin/backup.sh >> /var/log/lems-backup.log 2>&1" > /etc/crontabs/root
if [ "${BACKUP_ON_START:-0}" = "1" ]; then
  /usr/local/bin/backup.sh >> /var/log/lems-backup.log 2>&1 || echo "startup backup failed" >&2
fi
exec crond -f -d 8
