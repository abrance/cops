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

# chart 优先用仓库里随带的 tarball（apps/<unit>/chart/*.tgz）：CI runner 到 GitHub
# releases 时通时不通，2026-11-09 的校验就是 504 Gateway Timeout 红的，3 次快速
# 重试也没救回来。本地包在仓库里就完全不碰网络。升级 chart：换 tarball + 改 app.conf 的版本。
local_chart="$(ls -1 "${UNIT_DIR}"/chart/*.tgz 2>/dev/null | head -1 || true)"

# helm_retry：这两个步骤都要实时联网（repo index + chart tarball 走 GitHub releases，
# 冷启动约 30s）。网络抖一下就整条 Deploy 红，2026-11-08 的定时全量部署就是这样红的：
# 唯一失败的 `校验 apps/openbao` 把下面两个命令的 stderr 全丢掉了，日志里只剩
# 「Process completed with exit code 1」，连是网络还是 values.yaml 都不出来。
# 所以这里：网络类步骤最多重试 3 次，且最终失败必须把 helm 的真实报错打到 stderr。
# 只重试 repo add / 拉 chart；渲染产物本身的错误（模板语法、values 类型不符）照样一次就红。
helm_retry() {
  local attempt=1 log
  log="$(mktemp)"
  while :; do
    if "$@" >"${log}" 2>&1; then
      cat "${log}"
      rm -f "${log}"
      return 0
    fi
    if [ "${attempt}" -ge 3 ]; then
      echo "命令失败（已重试 ${attempt} 次）：$*" >&2
      sed 's/^/  /' "${log}" >&2
      rm -f "${log}"
      return 1
    fi
    echo "第 ${attempt} 次失败，${attempt} 秒后重试：$*" >&2
    sleep "${attempt}"
    attempt=$((attempt + 1))
  done
}

# --force-update：runner 若缓存了同名但不同 URL 的 repo，不加这个会直接报
# 「repository name already exists」，与网络无关却同样红。
if [ -z "${local_chart}" ]; then
  if ! helm_retry helm repo add --force-update "${repo_name}" "${CHART_REPO}" >/dev/null; then
    echo "helm repo add ${repo_name} ${CHART_REPO} 失败" >&2
    exit 1
  fi
  chart_ref="${CHART}"
else
  echo "使用仓库内 chart：${local_chart}" >&2
  chart_ref="${local_chart}"
fi

chart_out="$(mktemp)"
trap 'rm -f "${chart_out}"' EXIT
if ! helm_retry helm template "${NAME}" "${chart_ref}" --version "${CHART_VERSION}" -f "${VALUES}" >"${chart_out}"; then
  echo "helm template ${CHART} --version ${CHART_VERSION} 失败" >&2
  exit 1
fi

python3 -c '
import re, sys
text = sys.stdin.read()
docs = [c for c in re.split(r"(?m)^---[ \t]*$", text) if c.strip() and "helm.sh/hook" not in c]
# 输出必须带前导 ---：CI 把本输出追加到 render-k8s.py 的产物后面，后者结尾没有分隔符。
print("---\n" + "---\n".join(docs))

' < "${chart_out}"