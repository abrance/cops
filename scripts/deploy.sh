#!/usr/bin/env bash
# cops 部署脚本：在云主机上执行，应用单个部署单元的期望状态。
#
# 由 .github/workflows/deploy.yml 通过 stdin 传入：
#   ssh <host> "bash -s -- <scope> <name>" < scripts/deploy.sh
#   scope: apps（应用）或 environment（应用依赖的环境组件，如中间件）
#
# 约定的服务器目录：
#   /opt/cops/apps/<name>/         应用期望状态（由 CI 同步）
#   /opt/cops/environment/<name>/  环境组件期望状态（由 CI 同步）
#   /opt/cops/secrets/<name>.env   可选运行期密钥（服务器本地维护，不入库）
#
# app.conf 可声明：
#   HEALTH_CONTAINER / HEALTH_TIMEOUT / HEALTH_URL  健康检查
#   REQUIRED_ENV                                    部署前必须非空的变量名（空格分隔）
set -euo pipefail

APP="${1:?用法: deploy.sh <name> [apps|environment]}"
SCOPE="${2:-apps}"
case "${SCOPE}" in
  apps | environment) ;;
  *)
    echo "未知部署范围 ${SCOPE}：用法 deploy.sh <名字> <apps|environment>（只支持这两种）" >&2
    exit 1
    ;;
esac
BASE_PATH="${COPS_BASE_PATH:-/opt/cops}"
APP_DIR="${BASE_PATH}/${SCOPE}/${APP}"
SECRETS_FILE="${BASE_PATH}/secrets/${APP}.env"

log() { printf '==> [%s] %s\n' "${APP}" "$*"; }

# 应用元数据（部署模式、健康检查、必需变量）
if [ -f "${APP_DIR}/app.conf" ]; then
  # shellcheck disable=SC1090,SC1091
  . "${APP_DIR}/app.conf"
fi

MODE="${DEPLOY_MODE:-compose}"

if [ ! -d "${APP_DIR}" ]; then
  echo "找不到部署目录 ${APP_DIR}：确认 <名字> 与 <scope> 写对（环境组件必须传 environment）" >&2
  exit 1
fi

cd "${APP_DIR}"

# 从 .env 与 secrets 文件按顺序取值（后者优先），用于必需变量检查
env_lookup() {
  key="$1"
  val=""
  for f in .env "${SECRETS_FILE}"; do
    [ -f "${f}" ] || continue
    line="$(sed -n "s/^${key}=//p" "${f}" | tail -1)"
    if [ -n "${line}" ]; then
      val="${line}"
    fi
  done
  printf '%s' "${val}"
}

for key in ${REQUIRED_ENV:-}; do
  if [ -z "$(env_lookup "${key}")" ]; then
    log "缺少必需变量 ${key}，请写入 ${SECRETS_FILE}"
    exit 1
  fi
done

# native 模式：非容器交付（发布包 + systemd），交给应用自带的部署脚本
if [ "${MODE}" = "native" ]; then
  NATIVE_SCRIPT="${APP_DIR}/native/deploy-native.sh"
  if [ ! -f "${NATIVE_SCRIPT}" ]; then
    echo "DEPLOY_MODE=native 但缺少 ${NATIVE_SCRIPT}" >&2
    exit 1
  fi
  log "native 部署模式"
  exec bash "${NATIVE_SCRIPT}" "${APP}"
fi

if [ ! -f "${APP_DIR}/compose.yaml" ]; then
  echo "未找到 ${APP_DIR}/compose.yaml，无法部署" >&2
  exit 1
fi

COMPOSE_ARGS=(--env-file .env)
if [ -f "${SECRETS_FILE}" ]; then
  log "加载运行期密钥 ${SECRETS_FILE}"
  COMPOSE_ARGS+=(--env-file "${SECRETS_FILE}")
fi

log "拉取镜像"
docker compose "${COMPOSE_ARGS[@]}" pull

log "应用期望状态"
docker compose "${COMPOSE_ARGS[@]}" up -d --remove-orphans

if [ -n "${HEALTH_CONTAINER:-}" ]; then
  log "等待容器 ${HEALTH_CONTAINER} 健康"
  deadline=$(( $(date +%s) + ${HEALTH_TIMEOUT:-180} ))
  while :; do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${HEALTH_CONTAINER}" 2>/dev/null || echo missing)"
    case "${status}" in
      healthy | running)
        log "容器 ${HEALTH_CONTAINER} 状态: ${status}"
        break
        ;;
      unhealthy | exited | dead)
        log "容器 ${HEALTH_CONTAINER} 状态异常: ${status}"
        docker logs --tail 50 "${HEALTH_CONTAINER}" 2>&1 || true
        exit 1
        ;;
    esac
    if [ "$(date +%s)" -ge "${deadline}" ]; then
      log "等待容器 ${HEALTH_CONTAINER} 超时（最后状态: ${status}）"
      docker logs --tail 50 "${HEALTH_CONTAINER}" 2>&1 || true
      exit 1
    fi
    sleep 5
  done
fi

if [ -n "${HEALTH_URL:-}" ]; then
  log "探测健康接口 ${HEALTH_URL}"
  # 容器“运行中”不等于服务已就绪：没有 healthcheck 的容器（如网关要加载本地模型）
  # 起来后需要几秒才监听端口，所以探测要在 HEALTH_TIMEOUT 内重试。
  deadline=$(( $(date +%s) + ${HEALTH_TIMEOUT:-180} ))
  attempt=0
  last_error=""
  while :; do
    attempt=$(( attempt + 1 ))
    # stderr 捕获 curl 的错误信息，stdout（响应体）丢弃
    if last_error="$(curl -fsS --max-time 10 "${HEALTH_URL}" 2>&1 >/dev/null)"; then
      log "健康探测通过（第 ${attempt} 次尝试）"
      break
    fi
    if [ "$(date +%s)" -ge "${deadline}" ]; then
      log "健康探测失败: ${HEALTH_URL}（已尝试 ${attempt} 次，最后一次错误：${last_error:-无输出，可能返回非 2xx}）"
      exit 1
    fi
    sleep 3
  done
fi

log "当前容器状态"
docker compose "${COMPOSE_ARGS[@]}" ps

# ── 磁盘回收 ─────────────────────────────────────────────────────────────────
#
# 每次部署都回收，避免镜像层与构建缓存长期累积把磁盘写满。
#
# 默认只做安全回收：悬空镜像（无 tag 的旧层）与过期的构建缓存。
# 已经打过 tag 的旧版本镜像不会被删，因为回滚要依赖它们。
#
# 若磁盘确实吃紧，可设 PRUNE_UNUSED_IMAGES=1 打开激进回收：
# 删除超过 IMAGE_RETENTION_HOURS 未被任何容器引用的镜像（含带 tag 的旧版本）。
# 代价是回滚时需要重新从镜像站拉取；在共享主机上还会波及本仓库之外的镜像，
# 因此默认关闭。
IMAGE_RETENTION_HOURS="${IMAGE_RETENTION_HOURS:-720}"
log "回收悬空镜像与过期构建缓存"
docker image prune -f >/dev/null 2>&1 || true
docker builder prune -f --filter "until=${IMAGE_RETENTION_HOURS}h" >/dev/null 2>&1 || true

if [ "${PRUNE_UNUSED_IMAGES:-0}" = "1" ]; then
  log "激进回收：删除 ${IMAGE_RETENTION_HOURS} 小时内未被引用的镜像"
  docker image prune -a -f --filter "until=${IMAGE_RETENTION_HOURS}h" >/dev/null 2>&1 || true
fi

DISK_USED_PCT="$(df -P / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
DISK_AVAIL="$(df -h / | awk 'NR==2 {print $4}')"
log "磁盘剩余 ${DISK_AVAIL}（已用 ${DISK_USED_PCT}%）"
if [ -n "${DISK_USED_PCT}" ] && [ "${DISK_USED_PCT}" -ge 85 ]; then
  log "警告：根分区已用 ${DISK_USED_PCT}%，建议设 PRUNE_UNUSED_IMAGES=1 重新部署，或手工清理无用的镜像与日志"
fi

log "完成"
