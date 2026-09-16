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
VERSION="${VECTORMAN_VERSION:?VECTORMAN_VERSION 未设置}"
SHA256="${VECTORMAN_TARBALL_SHA256:?VECTORMAN_TARBALL_SHA256 未设置}"
: "${HEALTH_URLS:?HEALTH_URLS 未设置}"
REL="${VERSION#v}"
ASSET="vectorman-${REL}-linux-x86_64.tar.gz"
URL="https://github.com/abrance/vectorman/releases/download/${VERSION}/${ASSET}"

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

log "下载 ${URL}"
curl -fSL --retry 3 --connect-timeout 20 -o "${TMP}/${ASSET}" "${URL}" \
  || die "下载失败: ${URL}"

log "校验 sha256"
printf '%s  %s\n' "${SHA256}" "${TMP}/${ASSET}" | sha256sum -c - \
  || die "sha256 校验失败（期望 ${SHA256}）"

tar xzf "${TMP}/${ASSET}" -C "${TMP}"
PKG="${TMP}/vectorman-${REL}-linux-x86_64"
[ -f "${PKG}/deploy/install.sh" ] || die "包内缺少 deploy/install.sh"

# ---------- 退役旧 apiserver（改名前组件）----------
OLD_UNIT=/etc/systemd/system/vectorman-apiserver.service
OLD_DIR="${ROOT}/apiserver"
NEW_DATA="${ROOT}/dataserver/data"

if sudo_run test -f "${OLD_UNIT}"; then
  log "停止旧服务 vectorman-apiserver.service"
  sudo_run systemctl stop vectorman-apiserver.service 2>/dev/null || true
fi

# 迁移历史数据：仅当目标不存在时执行一次
if sudo_run test -d "${OLD_DIR}/data" && ! sudo_run test -e "${NEW_DATA}"; then
  log "迁移数据 ${OLD_DIR}/data -> ${NEW_DATA}"
  sudo_run mkdir -p "${ROOT}/dataserver"
  sudo_run mv "${OLD_DIR}/data" "${NEW_DATA}"
fi

# ---------- 安装 ----------
log "安装到 ${ROOT}（install.sh all --with-systemd）"
sudo_run bash "${PKG}/deploy/install.sh" all --dest "${ROOT}" --with-systemd

# ---------- 下发期望配置 ----------
log "覆盖运行时配置"
sudo_run mkdir -p "${ROOT}/dataserver/data"
while IFS=: read -r name dest; do
  sudo_run mkdir -p "$(dirname "${dest}")"
  sudo_run cp "${APP_DIR}/conf/${name}" "${dest}"
done <<EOF
config.toml:${ROOT}/dataserver/config.toml
gse-server.toml:${ROOT}/gse-server/conf/gse-server.toml
gse-agent.toml:${ROOT}/gse-agent/conf/gse-agent.toml
console.toml:${ROOT}/console/conf/console.toml
EOF

# ---------- 退役旧 apiserver 的 unit 与目录 ----------
if sudo_run test -f "${OLD_UNIT}"; then
  log "退役旧 unit ${OLD_UNIT}"
  sudo_run systemctl disable vectorman-apiserver.service 2>/dev/null || true
  sudo_run rm -f "${OLD_UNIT}"
fi
if sudo_run test -d "${OLD_DIR}"; then
  log "移除旧组件目录 ${OLD_DIR}"
  sudo_run rm -rf "${OLD_DIR}"
fi

# ---------- 应用期望状态（幂等）----------
sudo_run mkdir -p "${ROOT}/deploy"
STATE_FILE="${ROOT}/deploy/vectorman-state.sha256"
desired_state="$(
  {
    echo "version=${VERSION}"
    for f in "${APP_DIR}"/conf/*; do
      echo "--- $(basename "${f}") ---"
      cat "${f}"
    done
  } | sha256sum | awk '{print $1}'
)"
previous_state="$(sudo_run cat "${STATE_FILE}" 2>/dev/null || true)"

sudo_run systemctl daemon-reload
sudo_run systemctl enable "${UNITS[@]}" >/dev/null 2>&1 || true

if [ "${desired_state}" != "${previous_state}" ]; then
  log "期望状态有变化，重启服务"
  sudo_run systemctl restart "${UNITS[@]}"
  # 注意：不能用 `printf | sudo_run tee`——sudo -S 会先把 stdin 的密码行吃掉，
  # tee 就读不到内容了。改为经 argv 写文件，不经过 stdin。
  sudo_run bash -c 'printf "%s\n" "$1" > "$2"' _ "${desired_state}" "${STATE_FILE}"
else
  log "期望状态未变化，确保服务在运行"
  for unit in "${UNITS[@]}"; do
    if ! sudo_run systemctl is-active --quiet "${unit}"; then
      sudo_run systemctl start "${unit}"
    fi
  done
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
