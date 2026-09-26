#!/usr/bin/env bash
# vectorman native 部署脚本（cops DEPLOY_MODE=native）
#
# 由 scripts/deploy.sh 在云主机上以 xiaoy 身份执行：
#   bash /opt/cops/apps/vectorman/native/deploy-native.sh vectorman
#
# 职责：
#   1. 从 GitHub Releases 下载锁定版本的 musl 静态二进制包并校验 sha256
#   2. 停止并退役旧的 apiserver 服务，迁移其历史数据
#   3. sudo 调用包内 install.sh --with-systemd 安装组件与 systemd unit
#   4. 用仓库 conf/ 下的期望 TOML 覆盖运行时配置（仓库即唯一事实源）
#   5. 期望状态变化时重启服务，否则只确保服务在运行（幂等）
#   6. 按 HEALTH_URLS 做健康探测
#
# root 需求：install.sh --with-systemd 会写 /etc/systemd/system 与 /opt/vectorman。
# sudo 密码由 CI 经 /opt/cops/secrets/vectorman.env 下发（600），读取后立即清除。
set -euo pipefail

APP="${1:?用法: deploy-native.sh <app>}"
BASE_PATH="${COPS_BASE_PATH:-/opt/cops}"
APP_DIR="${BASE_PATH}/apps/${APP}"
SECRETS_FILE="${BASE_PATH}/secrets/${APP}.env"

log() { printf '==> [%s] %s\n' "${APP}" "$*"; }
die() { echo "==> [${APP}] ERROR: $*" >&2; exit 1; }

# ---------- 期望状态 ----------
# shellcheck disable=SC1091
. "${APP_DIR}/.env"
# shellcheck disable=SC1091
. "${APP_DIR}/app.conf"

ROOT="${VECTORMAN_INSTALL_ROOT:?VECTORMAN_INSTALL_ROOT 未设置}"
ARTIFACT_URL="${NATIVE_ARTIFACT_URL:?NATIVE_ARTIFACT_URL 未设置}"
SHA256="${NATIVE_ARTIFACT_SHA256:?NATIVE_ARTIFACT_SHA256 未设置}"
: "${HEALTH_URLS:?HEALTH_URLS 未设置}"
ARTIFACT_NAME="${ARTIFACT_URL##*/}"
PKG_NAME="${ARTIFACT_NAME%.tar.gz}"
CACHE_DIR="${BASE_PATH}/cache/${APP}"
CACHE_FILE="${CACHE_DIR}/${ARTIFACT_NAME}"

UNITS=(
  vectorman-gse-server.service
  vectorman-gse-agent.service
  vectorman-dataserver.service
  vectorman-console.service
)

# ---------- sudo ----------
[ -f "${SECRETS_FILE}" ] || die "缺少 ${SECRETS_FILE}（应含 VECTORMAN_SUDO_PASS）"
SUDO_PASS="$(sed -n 's/^VECTORMAN_SUDO_PASS=//p' "${SECRETS_FILE}" | tail -1)"
[ -n "${SUDO_PASS}" ] || die "VECTORMAN_SUDO_PASS 为空"

# 密码只在内存中保留，立即从磁盘清除
if command -v shred >/dev/null 2>&1; then
  shred -u "${SECRETS_FILE}" 2>/dev/null || rm -f "${SECRETS_FILE}"
else
  rm -f "${SECRETS_FILE}"
fi

sudo_run() { printf '%s\n' "${SUDO_PASS}" | sudo -S -p '' "$@"; }

sudo_run true 2>/dev/null || die "sudo 认证失败（VECTORMAN_SUDO_PASS 与主机 sudo 密码不一致）"
log "sudo 认证通过"

# ---------- 下载与校验 ----------
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# 优先使用 CI 暂存的产物；主机直连 GitHub 不可靠，下载仅作回退
if [ -f "${CACHE_FILE}" ]; then
  log "使用 CI 暂存产物 ${CACHE_FILE}"
  cp "${CACHE_FILE}" "${TMP}/${ARTIFACT_NAME}"
else
  log "未找到暂存产物，回退为主机下载 ${ARTIFACT_URL}"
  curl -fSL --retry 3 --connect-timeout 20 -o "${TMP}/${ARTIFACT_NAME}" "${ARTIFACT_URL}" \
    || die "下载失败: ${ARTIFACT_URL}"
fi

log "校验 sha256"
printf '%s  %s\n' "${SHA256}" "${TMP}/${ARTIFACT_NAME}" | sha256sum -c - \
  || die "sha256 校验失败（期望 ${SHA256}）"

tar xzf "${TMP}/${ARTIFACT_NAME}" -C "${TMP}"
PKG="${TMP}/${PKG_NAME}"
[ -f "${PKG}/deploy/install.sh" ] || die "包内缺少 deploy/install.sh"

# ---------- 期望状态与安装判定 ----------
# 期望状态 = 产物（名 + sha256）+ 全部期望配置内容。
# 未变化时完全跳过安装，避免无谓停机，也避免覆盖运行中的二进制。
# 安装前需停止的 unit：现役四件套 + 改名前的 apiserver
STOP_UNITS=(vectorman-apiserver.service "${UNITS[@]}")
OLD_UNIT=/etc/systemd/system/vectorman-apiserver.service
OLD_DIR="${ROOT}/apiserver"
NEW_DATA="${ROOT}/dataserver/data"
STATE_FILE="${ROOT}/deploy/vectorman-state.sha256"
desired_state="$(
  {
    echo "artifact=${ARTIFACT_NAME}"
    echo "sha256=${SHA256}"
    for f in "${APP_DIR}"/conf/*; do
      echo "--- $(basename "${f}") ---"
      cat "${f}"
    done
  } | sha256sum | awk '{print $1}'
)"
previous_state="$(sudo_run cat "${STATE_FILE}" 2>/dev/null || true)"

if [ "${desired_state}" = "${previous_state}" ]; then
  # 幂等快路径：不停止、不安装、不重启，只确保服务在运行
  log "期望状态未变化，跳过安装"
  for unit in "${UNITS[@]}"; do
    if ! sudo_run systemctl is-active --quiet "${unit}"; then
      log "  ${unit} 未运行，启动"
      sudo_run systemctl start "${unit}"
    fi
  done
else
  # ---------- 停止现有服务 ----------
  # install.sh 用 cp 就地覆盖二进制。对正在运行的进程覆盖会得到 ETXTBSY，
  # 因此安装前必须停掉所有 vectorman unit（含改名前的 apiserver）。
  for unit in "${STOP_UNITS[@]}"; do
    if sudo_run systemctl is-active --quiet "${unit}" 2>/dev/null; then
      log "停止 ${unit}"
      sudo_run systemctl stop "${unit}" || true
    fi
  done

  # 等进程完全退出，确保文件句柄已释放
  for _ in $(seq 1 20); do
    busy=0
    for unit in "${STOP_UNITS[@]}"; do
      if sudo_run systemctl is-active --quiet "${unit}" 2>/dev/null; then
        busy=1
      fi
    done
    [ "${busy}" -eq 0 ] && break
    sleep 1
  done

  # 迁移历史数据：仅当目标不存在时执行一次
  if sudo_run test -d "${OLD_DIR}/data" && ! sudo_run test -e "${NEW_DATA}"; then
    log "迁移数据 ${OLD_DIR}/data -> ${NEW_DATA}"
    sudo_run mkdir -p "${ROOT}/dataserver"
    sudo_run mv "${OLD_DIR}/data" "${NEW_DATA}"
  fi

  log "安装到 ${ROOT}（install.sh all --with-systemd）"
  sudo_run bash "${PKG}/deploy/install.sh" all --dest "${ROOT}" --with-systemd

  log "覆盖运行时配置"
  sudo_run mkdir -p "${ROOT}/dataserver/data" "${ROOT}/deploy"
  while IFS=: read -r name dest; do
    sudo_run mkdir -p "$(dirname "${dest}")"
    sudo_run cp "${APP_DIR}/conf/${name}" "${dest}"
  done <<EOF
config.toml:${ROOT}/dataserver/config.toml
gse-server.toml:${ROOT}/gse-server/conf/gse-server.toml
gse-agent.toml:${ROOT}/gse-agent/conf/gse-agent.toml
console.toml:${ROOT}/console/conf/console.toml
EOF

  # token 占位替换：conf/gse-agent.toml 里的 token 是占位符（凭据不进公开仓库），
  # 这里用运行期密钥 VECTORMAN_AGENT_TOKEN 落到云主机的配置文件上。
  agent_token="$(sed -n 's/^VECTORMAN_AGENT_TOKEN=//p' "${SECRETS_FILE}" | tail -1)"
  [ -n "${agent_token}" ] || die "SECRETS 里缺少 VECTORMAN_AGENT_TOKEN（cloud3 的 server 开了鉴权）"
  sudo_run sed -i "s|^token = .*|token = "${agent_token}"|" "${ROOT}/gse-agent/conf/gse-agent.toml"
  unset agent_token

  # 退役改名前的旧 apiserver
  if sudo_run test -f "${OLD_UNIT}"; then
    log "退役旧 unit ${OLD_UNIT}"
    sudo_run systemctl disable vectorman-apiserver.service 2>/dev/null || true
    sudo_run rm -f "${OLD_UNIT}"
  fi
  if sudo_run test -d "${OLD_DIR}"; then
    log "移除旧组件目录 ${OLD_DIR}"
    sudo_run rm -rf "${OLD_DIR}"
  fi

  sudo_run systemctl daemon-reload
  sudo_run systemctl enable "${UNITS[@]}" >/dev/null 2>&1 || true
  log "期望状态有变化，重启服务"
  sudo_run systemctl restart "${UNITS[@]}"
  # 注意：不能用 `printf | sudo_run tee`——sudo -S 会先把 stdin 的密码行吃掉，
  # tee 就读不到内容了。改为经 argv 写文件，不经过 stdin。
  sudo_run bash -c 'printf "%s\n" "$1" > "$2"' _ "${desired_state}" "${STATE_FILE}"
fi

# ---------- 健康探测 ----------
log "健康探测"
deadline=$(( $(date +%s) + ${HEALTH_TIMEOUT:-180} ))
for url in ${HEALTH_URLS}; do
  ok=0
  while :; do
    if curl -fsS --max-time 5 "${url}" >/dev/null 2>&1; then
      ok=1
      break
    fi
    [ "$(date +%s)" -ge "${deadline}" ] && break
    sleep 3
  done
  if [ "${ok}" -ne 1 ]; then
    for unit in "${UNITS[@]}"; do
      echo "----- ${unit} -----" >&2
      sudo_run journalctl -u "${unit}" -n 30 --no-pager 2>/dev/null || true
    done
    die "健康探测失败: ${url}"
  fi
  log "  通过 ${url}"
done

log "服务状态"
sudo_run systemctl --no-pager --lines=0 status "${UNITS[@]}" 2>/dev/null || true
log "完成"
