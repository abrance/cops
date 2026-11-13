#!/usr/bin/env bash
# 跨单元一致性校验：同一台主机被多个单元引用时，引用值必须完全相同。
#
# 为什么需要：gdpm-proxy 的 PROXY_BIND（监听地址）和 lems-cloud3 的 PROXY_URL（连接地址）
# 是同一个 mesh 地址的两次硬编码。两处不一致时代理端口绑不上、lems 采集全部 failed/network，
# 与「源站不回包」的现象完全一样，只能靠人肉分辨。这里在 PR 阶段就把它炸出来。
#
# 由 .github/workflows/deploy.yml 的 validate job 在解析出的单元里调用：
#   scripts/check-mesh-consistency.sh apps/gdpm-proxy apps/lems-cloud3
# 也可以本地跑。只校验「两个单元都在本次变更范围内」的组合，未涉及的单元不重复报错。
set -euo pipefail

REPO_ROOT="${COPS_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "${REPO_ROOT}"

# .env 取值（与 render-k8s.py 的 parse_env 同规则：KEY=VALUE、支持 # 注释与成对引号）
env_get() {
  local file="$1" key="$2" line value
  [ -f "${file}" ] || return 1
  line="$(sed -n "s/^[[:space:]]*\(export[[:space:]]*\)\{0,1\}${key}=//p" "${file}" | tail -1)"
  [ -n "${line}" ] || return 1
  value="${line%\"}"; value="${value#\"}"
  value="${value%\'}"; value="${value#\'}"
  printf '%s' "${value}"
}

# 从 URL 里取 host:port
url_hostport() {
  local u="$1"
  u="${u#*://}"          # 去掉 scheme
  u="${u%%/*}"           # 去掉路径
  u="${u##*@}"           # 去掉 userinfo
  printf '%s' "${u}"
}

die() {
  echo "✗ mesh 地址不一致：$1" >&2
  echo "" >&2
  echo "  两处必须同时改：" >&2
  echo "    apps/gdpm-proxy/compose.yaml  的 environment.PROXY_BIND" >&2
  echo "    apps/lems-cloud3/.env         的 PROXY_URL" >&2
  echo "" >&2
  echo "  地址来自 easytier mesh 配置（/opt/easytier/config/default.conf，固定不是 DHCP）。" >&2
  exit 1
}

want_proxy="0"
want_lems="0"
for unit in "$@"; do
  case "${unit}" in
    apps/gdpm-proxy | gdpm-proxy) want_proxy="1" ;;
    apps/lems-cloud3 | lems-cloud3) want_lems="1" ;;
  esac
done

# 只有一个单元被改动时也校验：改错单个 .env 同样是事故。
[ "${want_proxy}" = "1" ] || [ "${want_lems}" = "1" ] || exit 0

proxy_compose="apps/gdpm-proxy/compose.yaml"
lems_env="apps/lems-cloud3/.env"

# 代理侧：compose.yaml 的 PROXY_BIND / PROXY_PORT
bind_raw="$(sed -n 's/^[[:space:]]*PROXY_BIND:[[:space:]]*"\?\([^"]*\)"\?[[:space:]]*$/\1/p' "${proxy_compose}" | tail -1)"
port_raw="$(sed -n 's/^[[:space:]]*PROXY_PORT:[[:space:]]*"\?\([^"]*\)"\?[[:space:]]*$/\1/p' "${proxy_compose}" | tail -1)"
[ -n "${bind_raw}" ] || die "在 ${proxy_compose} 里找不到 PROXY_BIND"
[ -n "${port_raw}" ] || die "在 ${proxy_compose} 里找不到 PROXY_PORT"

# lems 侧：PROXY_URL=http://<host>:<port>
proxy_url="$(env_get "${lems_env}" PROXY_URL || true)"
[ -n "${proxy_url}" ] || die "在 ${lems_env} 里找不到 PROXY_URL"
url_hp="$(url_hostport "${proxy_url}")"
url_host="${url_hp%:*}"
url_port="${url_hp##*:}"
[ -n "${url_host}" ] && [ -n "${url_port}" ] || die "PROXY_URL=${proxy_url} 不是 http://<host>:<port> 形式"

proxy_hp="${bind_raw}:${port_raw}"
if [ "${url_hp}" != "${proxy_hp}" ]; then
  die "gdpm-proxy 监听 ${proxy_hp}，但 lems-cloud3 连 ${url_hp}（PROXY_URL=${proxy_url}）"
fi

echo "✓ mesh 地址一致：${proxy_hp}（proxy PROXY_BIND/PORT 与 lems PROXY_URL 同值）"
