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
  if ! curl -fsS --max-time 10 "${HEALTH_URL}" >/dev/null; then
    log "健康探测失败: ${HEALTH_URL}"
    exit 1
  fi
  log "健康探测通过"
fi

log "当前容器状态"
docker compose "${COMPOSE_ARGS[@]}" ps
log "完成"
