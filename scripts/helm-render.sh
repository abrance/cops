#!/usr/bin/env bash
# helm chart 单元的渲染：repo add → helm template → 过滤 helm test 资源。
# 输出到 stdout，供 CI 拼进 rendered.yaml（与 render-k8s.py 的输出合并）。
#
#   scripts/helm-render.sh <单元目录>
#
# 单元 app.conf 需声明：
#   HELM_CHART_REPO     chart 的 helm 仓库地址（如 https://openbao.github.io/openbao-helm）
#   HELM_CHART          chart 名（如 openbao/openbao）
#   HELM_CHART_VERSION  锁定版本（如 0.30.2）
# 单元目录里还要有 values.yaml（chart 的自定义 values）。
#
# 为什么过滤 helm test 资源：chart 里带 helm.sh/hook: test 注解的 Pod（如
# openbao-server-test）是给 `helm test`/`helm install` 的 hook 用的。本仓库用
# `kubectl apply` 应用渲染产物，kubectl 不认 hook 注解，会把它当普通 Pod 创建，
# 测试在 sealed 状态下必然失败，于是命名空间里永远躺着一个 Failed 的 Pod。
# 校验/部署两侧都过滤，保证 apply 的对象和本地渲染一致。
set -euo pipefail

UNIT_DIR="${1:?用法: helm-render.sh <单元目录>}"
CONF="${UNIT_DIR}/app.conf"
VALUES="${UNIT_DIR}/values.yaml"

if [ ! -f "${CONF}" ]; then
  echo "缺少 ${CONF}：helm chart 单元必须有 app.conf" >&2
  exit 1
fi
if [ ! -f "${VALUES}" ]; then
  echo "缺少 ${VALUES}：helm chart 单元必须有 values.yaml" >&2
  exit 1
fi

# 从 app.conf 读 HELM_CHART_REPO / HELM_CHART / HELM_CHART_VERSION
# （不 source 整个文件：app.conf 里可能有其它 shell 语法，这里只取需要的键）
read_conf() {
  local key="$1"
  local value
  value="$(sed -n "s/^${key}=//p" "${CONF}" | tail -1)"
  value="${value%\"}"
  value="${value#\"}"
  if [ -n "${value}" ]; then
    printf '%s' "${value}"
    return 0
  fi
  return 1
}

CHART_REPO="$(read_conf HELM_CHART_REPO)" || { echo "app.conf 缺 HELM_CHART_REPO" >&2; exit 1; }
CHART="$(read_conf HELM_CHART)" || { echo "app.conf 缺 HELM_CHART" >&2; exit 1; }
CHART_VERSION="$(read_conf HELM_CHART_VERSION)" || { echo "app.conf 缺 HELM_CHART_VERSION" >&2; exit 1; }
NAME="$(read_conf APP_NAME)" || { echo "app.conf 缺 APP_NAME" >&2; exit 1; }

repo_name="${CHART%%/*}"
if [ -z "${repo_name}" ] || [ "${repo_name}" = "${CHART}" ]; then
  echo "HELM_CHART 应为 <repo>/<chart> 形式，实际：${CHART}" >&2
  exit 1
fi

if ! helm repo add "${repo_name}" "${CHART_REPO}" >/dev/null 2>&1; then
  echo "helm repo add ${repo_name} ${CHART_REPO} 失败" >&2
  exit 1
fi

helm template "${NAME}" "${CHART}" --version "${CHART_VERSION}" \
  -f "${VALUES}" 2>/dev/null \
  | python3 -c '
import re, sys
text = sys.stdin.read()
docs = [c for c in re.split(r"(?m)^---[ \t]*$", text) if c.strip() and "helm.sh/hook" not in c]
# 输出必须带前导 ---：CI 把本输出追加到 render-k8s.py 的产物后面，后者结尾没有分隔符。
print("---\n" + "---\n".join(docs))

'