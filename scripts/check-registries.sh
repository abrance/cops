#!/usr/bin/env bash
# 镜像源守卫：检查单元的 *_IMAGE 是否用在该主机允许的 registry 上。
#
#   scripts/check-registries.sh <单元目录> <目标主机>
#
# 为什么要这条检查：
#   registry 是**按主机**不同的。`ghcr.chenby.cn` 只对旧主机放行（cloud3 访问会被
#   Cloudflare 拦成 403），而 cloud3 只能用 `ghcr.io`。这条差异写在文档里会被忘掉，
#   所以把它变成 PR 阶段的硬失败——否则要等到部署时才发现拉不动镜像。
#   允许的 registry 由 hosts.yaml 的 `registries` 字段声明（见 scripts/hosts.sh）。
#
# 判定规则：
#   - 只看 `*_IMAGE=` 键（`*_IMAGE_TAG`、`NATIVE_ARTIFACT_URL` 等不参与）
#   - 取值的 registry 部分 = 第一个 `/` 之前；没有 `/`、或前缀既不含 `.` 也不含 `:`
#     （如 `qdrant/qdrant`）视为 docker.io
#   - 单元没有任何 *_IMAGE（例如 native 交付）时直接通过
set -euo pipefail

UNIT_DIR="${1:?用法: check-registries.sh <单元目录> <目标主机>}"
TARGET="${2:?用法: check-registries.sh <单元目录> <目标主机>}"

REPO_ROOT="${COPS_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HOSTS_SH="${REPO_ROOT}/scripts/hosts.sh"

if [ ! -d "${UNIT_DIR}" ]; then
  echo "找不到单元目录 ${UNIT_DIR}" >&2
  exit 1
fi

ALLOWED="$(bash "${HOSTS_SH}" "${TARGET}" registries)" || exit 1
ENV_FILE="${UNIT_DIR}/.env"

if [ ! -f "${ENV_FILE}" ]; then
  echo "单元 ${UNIT_DIR} 没有 .env（无可检查的镜像），跳过"
  exit 0
fi

# 取 *_IMAGE= 的键值（忽略注释与空值）
images="$(grep -E '^[A-Z0-9_]+_IMAGE=' "${ENV_FILE}" || true)"
if [ -z "${images}" ]; then
  echo "单元 ${UNIT_DIR} 未声明 *_IMAGE（如 native 交付），跳过"
  exit 0
fi

violations=""
checked=0
while IFS= read -r line; do
  [ -n "${line}" ] || continue
  key="${line%%=*}"
  value="${line#*=}"
  value="${value%\"}"
  value="${value#\"}"
  [ -n "${value}" ] || continue

  prefix="${value%%/*}"
  case "${prefix}" in
    *.* | *:*) registry="${prefix}" ;;
    *) registry="docker.io" ;;
  esac

  checked=$(( checked + 1 ))
  if printf ' %s ' "${ALLOWED}" | grep -q " ${registry} "; then
    printf '  ok      %-34s %s -> %s\n' "${key}" "${value}" "${registry}"
  else
    printf '  违规    %-34s %s -> %s（不在允许列表）\n' "${key}" "${value}" "${registry}"
    violations="${violations}${key}=${value}（registry ${registry}）、"
  fi
done <<<"${images}"

if [ -n "${violations}" ]; then
  cat >&2 <<EOF

主机 ${TARGET} 允许的 registry：${ALLOWED}
${UNIT_DIR} 里有镜像不在允许列表：${violations}

原因通常是镜像源按主机不同：
  - 旧主机（default）用 ghcr.chenby.cn（该站只对它放行）
  - cloud3 只能用 ghcr.io（访问 ghcr.chenby.cn 会被 Cloudflare 拦成 403）
改动单元目录时请只改 *_IMAGE_TAG，不要把 *_IMAGE 的 registry 换回去。
EOF
  exit 1
fi

echo "单元 ${UNIT_DIR} 的 ${checked} 个镜像都在主机 ${TARGET} 允许的 registry 内（${ALLOWED}）"
