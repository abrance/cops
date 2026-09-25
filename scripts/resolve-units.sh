#!/usr/bin/env bash
# cops 部署单元解析：根据触发事件与变更范围，算出本次要处理哪些单元。
#
# 由 .github/workflows/deploy.yml 的 resolve job 调用；也可以本地复现：
#
#   # 等价于「合入 main 后按变更计算」
#   EVENT_NAME=push BASE_SHA=HEAD~1 HEAD_SHA=HEAD scripts/resolve-units.sh
#   # 全部单元
#   EVENT_NAME=schedule scripts/resolve-units.sh
#   # 只解析某个单元
#   EVENT_NAME=workflow_dispatch REQUESTED=apps/model-ocr scripts/resolve-units.sh
#
# 输入（环境变量）：
#   EVENT_NAME  push | pull_request | schedule | workflow_dispatch
#   REQUESTED   workflow_dispatch 的 app 输入：<名字> 或 <scope>/<名字>，留空=全部
#   BASE_SHA    变更基线（push 用 github.event.before，PR 用 base.sha）
#   HEAD_SHA    变更终点（github.sha / head.sha）
#
# 输出：标准输出打印人读摘要；同时把 items（JSON 数组）写入 $GITHUB_OUTPUT（若已设置）。
#   items 元素：{"scope":"apps","name":"model-ocr","mode":"k8s","target":"cloud3"}
set -euo pipefail

REPO_ROOT="${COPS_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HOSTS_SH="${REPO_ROOT}/scripts/hosts.sh"

EVENT_NAME="${EVENT_NAME:-push}"
REQUESTED="${REQUESTED:-}"
BASE_SHA="${BASE_SHA:-}"
HEAD_SHA="${HEAD_SHA:-}"

cd "${REPO_ROOT}"

# 主机注册表先自检：结构写坏时不要让后面的 target 校验给出误导性结论
bash "${HOSTS_SH}" check >&2

list_all() {
  for scope in apps environment; do
    [ -d "${scope}" ] || continue
    for name in $(ls "${scope}"); do
      [ -d "${scope}/${name}" ] && echo "${scope}/${name}"
    done
  done
}

# 单元元数据：从 app.conf 读 DEPLOY_MODE / DEPLOY_TARGET
read_conf() {
  local dir="$1" key="$2" default="$3"
  if [ -f "${dir}/app.conf" ]; then
    local value
    value="$(sed -n "s/^${key}=//p" "${dir}/app.conf" | tail -1)"
    value="${value%\"}"
    value="${value#\"}"
    if [ -n "${value}" ]; then
      printf '%s' "${value}"
      return
    fi
  fi
  printf '%s' "${default}"
}

# 计算候选单元
if [ -n "${REQUESTED}" ]; then
  case "${REQUESTED}" in
    */*)
      candidates="${REQUESTED}"
      ;;
    *)
      candidates=""
      for scope in apps environment; do
        if [ -d "${scope}/${REQUESTED}" ]; then
          candidates="${candidates} ${scope}/${REQUESTED}"
        fi
      done
      if [ -z "${candidates}" ]; then
        echo "找不到部署单元 ${REQUESTED}：apps/ 与 environment/ 下都没有这个目录" >&2
        exit 1
      fi
      ;;
  esac
elif [ "${EVENT_NAME}" = "schedule" ] || [ "${EVENT_NAME}" = "workflow_dispatch" ]; then
  candidates="$(list_all)"
else
  if [ "${EVENT_NAME}" = "pull_request" ]; then
    base="${BASE_SHA}"
    head="${HEAD_SHA}"
  else
    base="${BASE_SHA}"
    head="${HEAD_SHA}"
  fi
  if [ -z "${base}" ] \
    || [ "${base}" = "0000000000000000000000000000000000000000" ] \
    || ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
    # 首次推送或基线不可用：无法计算增量，保守地部署全部
    candidates="$(list_all)"
  else
    changed="$(git diff --name-only "${base}" "${head}")"
    if grep -Eq '^(scripts/|hosts\.yaml$|\.github/workflows/deploy\.yml$)' <<<"${changed}"; then
      # 部署逻辑自身变更：全量部署以应用新逻辑
      candidates="$(list_all)"
    elif grep -Eq '^(apps|environment)/' <<<"${changed}"; then
      candidates="$(grep -E '^(apps|environment)/' <<<"${changed}" | awk -F/ '{print $1"/"$2}' | sort -u)"
    else
      # 变更不涉及任何部署单元：无需部署
      candidates=""
    fi
  fi
fi

items="[]"
seen=""
for candidate in ${candidates}; do
  scope="${candidate%%/*}"
  name="${candidate#*/}"
  case "${scope}" in
    apps | environment) ;;
    *)
      echo "忽略未知范围: ${candidate}" >&2
      continue
      ;;
  esac
  if ! printf '%s' "${name}" | grep -Eq '^[a-z0-9][a-z0-9-]*$'; then
    echo "忽略非法名字: ${candidate}" >&2
    continue
  fi
  # 名字在两个范围之间必须唯一：密钥文件与容器名都按名字定位
  if printf ' %s ' "${seen}" | grep -q " ${name} "; then
    echo "名字在 apps/ 与 environment/ 之间冲突: ${name}" >&2
    exit 1
  fi
  seen="${seen} ${name}"

  mode="$(read_conf "${candidate}" DEPLOY_MODE compose)"
  target="$(read_conf "${candidate}" DEPLOY_TARGET default)"

  case "${mode}" in
    compose)
      if [ ! -f "${candidate}/compose.yaml" ]; then
        echo "忽略缺少 compose.yaml 的 compose 单元: ${candidate}" >&2
        continue
      fi
      ;;
    native)
      if [ ! -f "${candidate}/native/deploy-native.sh" ]; then
        echo "忽略缺少 native/deploy-native.sh 的 native 单元: ${candidate}" >&2
        continue
      fi
      ;;
    k8s)
      if [ ! -f "${candidate}/k8s.yaml" ]; then
        echo "忽略缺少 k8s.yaml 的 k8s 单元: ${candidate}" >&2
        continue
      fi
      if [ ! -f "${candidate}/.env" ]; then
        echo "k8s 单元 ${candidate} 缺少 .env（渲染 k8s.yaml 需要它提供变量）" >&2
        exit 1
      fi
      ;;
    *)
      echo "忽略未知 DEPLOY_MODE=${mode} 的单元: ${candidate}" >&2
      continue
      ;;
  esac

  # 目标主机必须已注册，且允许该部署模式
  if ! allowed="$(bash "${HOSTS_SH}" "${target}" drivers 2>&1)"; then
    echo "单元 ${candidate} 声明的 DEPLOY_TARGET=${target} 不在 hosts.yaml 中：${allowed}" >&2
    exit 1
  fi
  if ! printf ' %s ' "${allowed}" | grep -q " ${mode} "; then
    echo "单元 ${candidate} 的 DEPLOY_MODE=${mode} 与主机 ${target} 的 drivers=\"${allowed}\" 不匹配" >&2
    exit 1
  fi

  items="$(jq -c --arg s "${scope}" --arg n "${name}" --arg m "${mode}" --arg t "${target}" \
    '. + [{scope:$s,name:$n,mode:$m,target:$t}]' <<<"${items}")"
done

echo "待部署单元: ${items}"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "items=${items}" >>"${GITHUB_OUTPUT}"
fi
