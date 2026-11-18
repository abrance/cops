#!/usr/bin/env bash
# 把 GitHub Repository variables 注入单元的 .env（只在 CI runner 的工作区生效）。
#
# 为什么不在仓库里写死：URL/域名属于部署常量，放在 GitHub Repository variables
# 更好读、改完重跑部署即可，不用改代码；单元 .env 只保留镜像、端口、资源等状态。
#
# 用法：scripts/apply-repo-vars.sh apps/lems-cloud3
#
# 变量名映射：仓库 variable 名 -> 单元 .env 里的键名。
# 缺任何一个都会非零退出——不允许带着空地址上线。
set -euo pipefail

dir="${1:?用法: apply-repo-vars.sh <scope>/<unit>}"
dir="${dir#./}"
env_file="${dir}/.env"

[ -f "${env_file}" ] || exit 0

case "${dir}" in
  apps/lems-cloud3)
    pairs="
      PRICE_SYNC_BASE_URL=LEMS_PRICE_SYNC_BASE_URL
      HOME_MARKET_GATEWAY_BASE=LEMS_HOME_MARKET_GATEWAY_BASE
      GD_METRIC_URL=LEMS_GD_METRIC_URL
      SPOT_REPORT_WECHAT_HOST=LEMS_SPOT_REPORT_WECHAT_HOST
      FORECAST_BASE_URL=LEMS_FORECAST_BASE_URL
      QINIU_DOMAIN=LEMS_QINIU_DOMAIN
      OCR_BASE_URL=LEMS_OCR_BASE_URL
    "
    ;;
  apps/gdpm)
    pairs="GDPM_BASE_URL=GDPM_BASE_URL"
    ;;
  *)
    exit 0
    ;;
esac

for pair in ${pairs}; do
  dest="${pair%%=*}"
  src="${pair#*=}"
  value="${!src:-}"
  if [ -z "${value}" ]; then
    echo "缺少 GitHub Repository variable ${src}（${dir} 需要 ${dest}）" >&2
    exit 1
  fi

  python3 - "${env_file}" "${dest}" "${value}" <<'PY'
import sys

path, key, value = sys.argv[1:4]
lines = open(path, encoding="utf-8").read().splitlines()
out, found = [], False
for line in lines:
    if line.startswith(key + "="):
        out.append(f"{key}={value}")
        found = True
    else:
        out.append(line)
if not found:
    out.append(f"{key}={value}")
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
done
