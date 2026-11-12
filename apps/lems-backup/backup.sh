#!/bin/sh
# 权威副本在 ems 仓库 deploy/docker-compose/backup.sh（PR #132），本目录是同步副本；
# 改备份逻辑先改那边，再复制过来，不要两份各自演进。
# lems SQLite 在线备份：一致性快照 → 校验 → 异地 → 按保留策略清理本地。
#
# 为什么不能 cp：v1.0.65 起库是 WAL 模式（out/ 下有 db.sqlite3-wal/-shm），
# 直接拷主文件会拿到不含最近写入的残缺快照，且恢复时不报错。
# 这里用 SQLite 原生 Backup API（sqlite3 ".backup"），在线一致、不停容器。
#
# 跑在宿主机（Debian），不需要 sudo：库文件通过 docker 卷只读挂进容器读。
# 失败一律非零退出，cron 日志里能直接看出来。
set -eu

# ---- 可调参数：只改这一段 ----
BACKUP_DIR="${BACKUP_DIR:-/opt/cops/backup/lems}"         # 本地备份目录
OFFSITE="${OFFSITE-nas:/pool1_8t/public/backup/lems}"    # 异地目标 ssh:path；显式置空（OFFSITE=）= 不做异地
KEEP_DAILY="${KEEP_DAILY:-7}"                             # 本地保留日备份数
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"                           # 本地保留周备份数（UTC 周日那份）
KEEP_OFFSITE="${KEEP_OFFSITE:-7}"                         # 异地保留份数（至少留 1 份日备）
# ------------------------------

VOLUME="${VOLUME:-lems_lems-data}"   # 生产命名卷；演练时用 VOLUME=lems-drill_lems-data
DB="${DB:-db.sqlite3}"
SQLITE_IMAGE="${SQLITE_IMAGE:-ems-backup-tools:1}"  # 只需带 sqlite3 的小镜像
TABLES="${TABLES:-alarm_history log device price setting}"

TS=$(date -u +%Y%m%dT%H%M%SZ)
NAME="db-${TS}.sqlite3.gz"
PART=".db-${TS}.sqlite3.part"
LOG_PREFIX="[backup $(date '+%F %T %Z')]"

die() { echo "$LOG_PREFIX FAILED: $*" >&2; exit 1; }

mkdir -p "$BACKUP_DIR"

# 同一时刻只允许一个备份在跑，避免两份同时压库/互相覆盖
exec 9>"${BACKUP_DIR}/.backup.lock"
flock -n 9 || die "另一个备份正在进行（锁 ${BACKUP_DIR}/.backup.lock）"

# sqlite3 跑在哪，决定它眼里的路径——写死 /dst 会在容器内跑到卷外去（备份静默失败）。
#   本机有 sqlite3 且 VOLUME 是真实目录（备份容器内 VOLUME=/src）：直接用本机路径
#   其余情况（宿主机上是命名卷）：走 docker run，库挂 /src、备份目录挂 /dst
if command -v sqlite3 >/dev/null 2>&1 && [ -d "${VOLUME}" ]; then
  SRC_DIR="${VOLUME}"
  DST_DIR="${BACKUP_DIR}"
  sq() { sqlite3 "$@"; }
else
  SRC_DIR="/src"
  DST_DIR="/dst"
  sq() { docker run --rm -v "${VOLUME}:/src:ro" -v "${BACKUP_DIR}:/dst" \
           --entrypoint sqlite3 "$SQLITE_IMAGE" "$@"; }
fi

# 1) 一致性快照
echo "$LOG_PREFIX snapshot ${VOLUME}/${DB} -> ${BACKUP_DIR}/${NAME}"
sq "${SRC_DIR}/${DB}" ".backup '${DST_DIR}/${PART}'" || die "sqlite3 .backup 失败"

# 2) 校验：integrity_check + 关键表行数（行数落进 .last-backup 供事后比对）
# 只取 stdout：sqlite 的告警、shell 的 xtrace 都会走 stderr，混进来会把 ok 判成失败
ROWS=$(sq "${DST_DIR}/${PART}" "PRAGMA integrity_check; $(for t in $TABLES; do echo "select '$t=' || count(*) from $t;"; done)" 2>/dev/null) \
  || { rm -f "${BACKUP_DIR}/${PART}"; die "校验查询失败"; }
[ "$(printf '%s\n' "$ROWS" | head -n1)" = "ok" ] \
  || { rm -f "${BACKUP_DIR}/${PART}"; die "integrity_check 未通过: $ROWS"; }
COUNTS=$(printf '%s\n' "$ROWS" | tail -n +2 | tr '\n' ' ')

# 3) 压缩后落名（快照阶段用 .part，避免半成品被当成可用备份）
gzip -c "${BACKUP_DIR}/${PART}" > "${BACKUP_DIR}/${NAME}" || { rm -f "${BACKUP_DIR}/${PART}" "${BACKUP_DIR}/${NAME}"; die "gzip 失败"; }
rm -f "${BACKUP_DIR}/${PART}"
SIZE=$(stat -c%s "${BACKUP_DIR}/${NAME}")

# 4) 异地：先传成功，再动本地老备份
if [ -n "$OFFSITE" ]; then
  OFF_HOST=${OFFSITE%%:*}
  OFF_PATH=${OFFSITE#*:}
  # SSH_KEY / SSH_KNOWN_HOSTS 用于容器内跑：容器里没有 ~/.ssh/config 与默认 known_hosts，
  # 密钥和主机指纹都是只读挂进来的，必须显式指路径
  SSHO="-o BatchMode=yes -o ConnectTimeout=10"
  [ -n "${SSH_KEY:-}" ] && SSHO="$SSHO -i $SSH_KEY"
  [ -n "${SSH_KNOWN_HOSTS:-}" ] && SSHO="$SSHO -o UserKnownHostsFile=$SSH_KNOWN_HOSTS"
  # shellcheck disable=SC2086
  scp -q $SSHO "${BACKUP_DIR}/${NAME}" "${OFFSITE}/" \
    || die "异地传输失败（本地 ${NAME} 已保留）: ${OFFSITE}"
  # 按字节数核对，避免半截文件被当成备份
  # shellcheck disable=SC2086
  REMOTE_SIZE=$(ssh $SSHO "$OFF_HOST" "stat -c%s '${OFF_PATH}/${NAME}'" 2>/dev/null || echo 0)
  [ "$REMOTE_SIZE" = "$SIZE" ] || die "异地文件大小不符（本地 ${SIZE} / 异地 ${REMOTE_SIZE}），本地已保留"
  echo "$LOG_PREFIX offsite ok ${OFFSITE}/${NAME} bytes=${SIZE}"

  # 异地也按份数清，否则只增不减；清理失败只告警，不影响本次备份的成功判定
  # shellcheck disable=SC2086
  ssh $SSHO "$OFF_HOST" "ls -1t '${OFF_PATH}'/db-*.sqlite3.gz 2>/dev/null | tail -n +$((KEEP_OFFSITE + 1)) | xargs -r rm -f" \
    || echo "$LOG_PREFIX WARN 异地旧备份清理失败（不影响本次备份）" >&2
fi

# 5) 本地保留：最新 KEEP_DAILY 份全留，另外每天周日（UTC）那份额外留 KEEP_WEEKLY 份
#    只有异地成功（或未配置异地）才走到这里：异地挂了不会删掉本地唯一的副本
keep_list=$(ls -1t "${BACKUP_DIR}"/db-*.sqlite3.gz 2>/dev/null | head -n "$KEEP_DAILY")
# 周备份靠文件名的 UTC 日期判断：busybox 的 date 不支持 -d，这里用 posix 算式算星期几
weekly=$(ls -1t "${BACKUP_DIR}"/db-*.sqlite3.gz 2>/dev/null \
  | while read -r f; do
      d=$(basename "$f" | sed 's/^db-\([0-9]\{8\}\)T.*/\1/')
      y=$(printf '%s' "$d" | cut -c1-4); m=$(printf '%s' "$d" | cut -c5-6); dd=$(printf '%s' "$d" | cut -c7-8)
      # Zeller 同余求星期（1=周一 … 7=周日），不依赖 date -d
      wd=$(awk -v y="$y" -v m="$m" -v d="$dd" 'BEGIN{
        if (m<3){m+=12;y-=1}
        K=y%100; J=int(y/100)
        h=int(d + int(13*(m+1)/5) + K + int(K/4) + int(J/4) + 5*J)%7
        # h: 0=周六 1=周日 2=周一 ... 6=周五
        w=(h==0)?6:((h==1)?7:(h-1))
        print w
      }')
      [ "$wd" = "7" ] && echo "$f"
    done | head -n "$KEEP_WEEKLY")
for f in $(ls -1t "${BACKUP_DIR}"/db-*.sqlite3.gz 2>/dev/null); do
  printf '%s\n%s\n' "$keep_list" "$weekly" | grep -qxF "$f" && continue
  echo "$LOG_PREFIX prune $(basename "$f")"
  rm -f "$f"
done

# 6) 清 24h 前的半成品与失败标记：prune 只认 db-*.sqlite3.gz，.part / FAILED-* 否则永远留着。
#    清不掉（属主不同）只告警，不影响本次备份成功判定
find "$BACKUP_DIR" -maxdepth 1 -type f \( -name '*.part' -o -name 'FAILED-*' \) -mmin +1440 -print 2>/dev/null \
  | while read -r f; do
      rm -f "$f" 2>/dev/null && echo "$LOG_PREFIX prune stale $(basename "$f")" \
        || echo "$LOG_PREFIX WARN 无法删除残留 $(basename "$f")（属主不同？）" >&2
    done

echo "$LOG_PREFIX OK ${NAME} size=${SIZE} ${COUNTS}"
# 状态落一份在宿主机目录，容器/日志丢了它也在。
# 写不了不算备份失败：老方案（root 容器）留下的文件属主可能不同，备份本身已经成功。
printf '%s OK %s size=%s %s\n' "$(date '+%F %T %Z')" "${NAME}" "${SIZE}" "${COUNTS}" > "${BACKUP_DIR}/.last-backup" 2>/dev/null \
  || echo "$LOG_PREFIX WARN 无法写 ${BACKUP_DIR}/.last-backup（备份本身已成功）" >&2
