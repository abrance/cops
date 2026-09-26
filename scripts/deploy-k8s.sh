#!/usr/bin/env bash
# cops 部署脚本（k8s 模式）：在目标主机上执行，把渲染好的期望状态 apply 到 k3s。
#
# 由 .github/workflows/deploy.yml 通过 stdin 传入：
#   ssh <host> "bash -s -- <name> <scope>" < scripts/deploy-k8s.sh
#
# 约定：渲染由 CI 在 runner 侧完成（scripts/render-k8s.py），产物是同目录下的
# rendered.yaml；本脚本只做 apply + 等待 + 探测，不在主机上做模板渲染。
#
# 服务器目录：
#   /opt/cops/apps/<name>/         rendered.yaml / k8s.yaml / app.conf / .env
#   /opt/cops/environment/<name>/  同上
#   /opt/cops/secrets/<name>.env   可选运行期密钥（服务器本地维护，不入库）
#
# app.conf 可声明：
#   K8S_NAMESPACE    命名空间，默认 cops
#   K8S_ROLLOUT      需要等待 rollout 的对象（如 "deployment/model-ocr"，空格分隔可多个）
#   K8S_HEALTH       "Service:端口:路径"，从主机 curl Service 的 ClusterIP 探活（可省略）
#   PUBLIC_URL       可选的公网探活地址（如 https://ocr.xiaoyxq.top/healthz）
#   HEALTH_TIMEOUT   等待与探活的总超时秒数，默认 180
#   REQUIRED_ENV     部署前必须非空的变量名（空格分隔）
set -euo pipefail

APP="${1:?用法: deploy-k8s.sh <name> [apps|environment]}"
SCOPE="${2:-apps}"
case "${SCOPE}" in
  apps | environment) ;;
  *)
    echo "未知部署范围 ${SCOPE}：用法 deploy-k8s.sh <名字> <apps|environment>（只支持这两种）" >&2
    exit 1
    ;;
esac

BASE_PATH="${COPS_BASE_PATH:-/opt/cops}"
APP_DIR="${BASE_PATH}/${SCOPE}/${APP}"
SECRETS_FILE="${BASE_PATH}/secrets/${APP}.env"
RENDERED="${APP_DIR}/rendered.yaml"

log() { printf '==> [%s] %s\n' "${APP}" "$*"; }

if [ ! -d "${APP_DIR}" ]; then
  echo "找不到部署目录 ${APP_DIR}：确认 <名字> 与 <scope> 写对（环境组件必须传 environment）" >&2
  exit 1
fi

# 非交互 shell 不会加载 ~/.bash_aliases 里的 KUBECONFIG，而 k3s 自带的 kubectl
# 在未指定 kubeconfig 时会去读 root-only 的 /etc/rancher/k3s/k3s.yaml 并报
# permission denied。这里显式指向本用户的 kubeconfig。
if [ -z "${KUBECONFIG:-}" ]; then
  export KUBECONFIG="${HOME}/.kube/config"
fi
if [ ! -r "${KUBECONFIG}" ]; then
  echo "kubeconfig ${KUBECONFIG} 不存在或不可读：在目标主机上执行
  sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config && sudo chown \$(id -u):\$(id -g) ~/.kube/config && chmod 600 ~/.kube/config" >&2
  exit 1
fi

# shellcheck disable=SC1090
. "${APP_DIR}/app.conf"

if [ "${DEPLOY_MODE:-k8s}" != "k8s" ]; then
  echo "deploy-k8s.sh 只处理 DEPLOY_MODE=k8s 的单元，但 ${APP_DIR}/app.conf 是 ${DEPLOY_MODE:-未声明}" >&2
  exit 1
fi

NAMESPACE="${K8S_NAMESPACE:-cops}"
TIMEOUT="${HEALTH_TIMEOUT:-180}"

if [ ! -f "${RENDERED}" ]; then
  echo "缺少渲染产物 ${RENDERED}：k8s 单元由 CI 在 runner 侧渲染后同步，不要在主机上手工渲染" >&2
  exit 1
fi

# 必需变量检查：取值顺序 .env → secrets 文件（后者优先），与 deploy.sh 的 compose 路径一致
env_lookup() {
  key="$1"
  val=""
  for f in "${APP_DIR}/.env" "${SECRETS_FILE}"; do
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

dump_failure() {
  log "诊断信息"
  kubectl -n "${NAMESPACE}" get pods -o wide 2>&1 | sed 's/^/    /' || true
  for object in ${K8S_ROLLOUT:-}; do
    kubectl -n "${NAMESPACE}" describe "${object}" 2>&1 | tail -30 | sed 's/^/    /' || true
  done
  kubectl -n "${NAMESPACE}" get events --sort-by=.lastTimestamp 2>&1 | tail -20 | sed 's/^/    /' || true
  for object in ${K8S_ROLLOUT:-}; do
    kind="${object%%/*}"
    [ "${kind}" = "deployment" ] || continue
    name="${object##*/}"
    kubectl -n "${NAMESPACE}" logs "deploy/${name}" --all-containers --tail=50 2>&1 | sed 's/^/    /' || true
  done
}

log "应用期望状态到命名空间 ${NAMESPACE}"
if ! kubectl apply -f "${RENDERED}"; then
  log "kubectl apply 失败"
  dump_failure
  exit 1
fi
# ── checksum 注解 ────────────────────────────────────────────────────────────
#
# 问题：kubectl apply 一个改了内容的 ConfigMap，**不会**重启引用它的 Pod。
# kubelet 会把新内容同步进已挂载的卷（几十秒后），但进程不会重新读配置——
# 于是「部署成功」了，跑的却还是旧配置。这类漂移在 health 探测里看不出来。
#
# 做法：把 Deployment 引用的 ConfigMap 内容哈希后写进 podTemplate.annotations。
# 内容变 → 注解变 → podTemplate 变 → Deployment 自动滚动新 Pod。
# 注解值不变时不触发滚动，所以幂等。
#
# 实现要点（都是实测定的）：
#   - 用 `kubectl -o jsonpath={.data}` 整块取内容再 sha256，**不解析 JSON 文本**。
#     jsonpath 输出键序稳定（实测多次一致），且不受 `-o json` 缩进/格式影响；
#     awk/sed 解析 JSON 会栽在 4 空格缩进与 metadata 里同名键的误匹配上。
#   - 只用目标主机一定有的东西：kubectl / awk / grep / sha256sum。
#     k3s 主机没有 jq，也不保证有 python3。
#   - 只处理 rendered.yaml 里本单元声明的 ConfigMap，绝不碰别的单元的。
#
# 已知限制：只覆盖 Deployment → ConfigMap 的直接引用；无 ConfigMap 的单元
# （如 model-ocr）整段 no-op。
if kubectl -n "${NAMESPACE}" get configmap >/dev/null 2>&1; then
  CHECKSUM_ANNOTATION="cops.vectorman.cn/configmap-checksum"

  # 本单元声明的 ConfigMap 名：kind 行之后的第一个 name 字段（按文档边界扫）
  declared_cms="$(awk '
    /^kind: ConfigMap[[:space:]]*$/ { want=1; next }
    /^kind: / { want=0 }
    want && /^  name: / { sub(/^  name: /, ""); print; want=0 }
  ' "${RENDERED}" | sort -u)"

  if [ -n "${declared_cms}" ]; then
    log "为引用 ConfigMap 的 Deployment 注入 checksum 注解"

    for object in ${K8S_ROLLOUT:-}; do
      kind="${object%%/*}"
      [ "${kind}" = "deployment" ] || continue
      name="${object##*/}"

      # 该 Deployment 引用的 ConfigMap：volumes[].configMap.name 与
      # envFrom[].configMapRef.name。用 jsonpath 一次取两类，再去重。
      refs="$(kubectl -n "${NAMESPACE}" get deploy "${name}" \
        -o jsonpath='{.spec.template.spec.volumes[*].configMap.name}{"\n"}{.spec.template.spec.containers[*].envFrom[*].configMapRef.name}' \
        2>/dev/null | tr ' ' '\n' | grep -v '^$' | sort -u || true)"

      # 与本单元声明的求交集
      mine=""
      for cm in ${refs}; do
        if printf '%s\n' "${declared_cms}" | grep -qx "${cm}"; then
          mine="${mine} ${cm}"
        fi
      done
      [ -n "${mine}" ] || continue

      digest=""
      for cm in ${mine}; do
        # 读集群里的实际内容（不是 rendered.yaml 的文本）：对齐「此刻真实生效的东西」
        body="$(kubectl -n "${NAMESPACE}" get configmap "${cm}" -o jsonpath='{.data}' 2>/dev/null || true)"
        digest="${digest}${cm}=$(printf '%s' "${body}" | sha256sum | awk '{print $1}')\n"
      done
      checksum="$(printf '%s' "${digest}" | sha256sum | awk '{print $1}')"

      # 读当前注解值。⚠️ jsonpath 里含点的 key 必须转义（\.），否则返回空，
      # 会被误判成「未注入」而对每次都触发滚动。
      current="$(kubectl -n "${NAMESPACE}" get deploy "${name}" \
        -o "jsonpath={.spec.template.metadata.annotations.cops\.vectorman\.cn/configmap-checksum}" \
        2>/dev/null || true)"

      if [ "${current}" = "${checksum}" ]; then
        log "  ${name}: checksum 未变（${checksum:0:12}…），不需要滚动"
        continue
      fi
      log "  ${name}: checksum ${current:0:12}… → ${checksum:0:12}…"
      # patch podTemplate 而不是 annotate deploy：只有改 podTemplate 才会滚动
      kubectl -n "${NAMESPACE}" patch deploy "${name}" --type=merge \
        -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"${CHECKSUM_ANNOTATION}\":\"${checksum}\"}}}}}" >/dev/null
    done
  fi
fi

for object in ${K8S_ROLLOUT:-}; do
  log "等待 ${object} 完成 rollout（最长 ${TIMEOUT}s）"
  if ! kubectl -n "${NAMESPACE}" rollout status "${object}" --timeout="${TIMEOUT}s"; then
    log "${object} rollout 失败"
    dump_failure
    exit 1
  fi
done

# 健康探测：Service 的 ClusterIP 从主机直接可达（k3s 的 kube-proxy 规则在主机网络上），
# 不需要进 Pod 或起临时容器。格式 "Service:端口:路径"，如 model-logcluster:8080:/readyz
if [ -n "${K8S_HEALTH:-}" ]; then
  svc="${K8S_HEALTH%%:*}"
  rest="${K8S_HEALTH#*:}"
  port="${rest%%:*}"
  path="${rest#*:}"
  path="/${path#/}"   # 保证恰好一个前导斜杠
  log "探测 ${svc} 的健康接口"
  cluster_ip="$(kubectl -n "${NAMESPACE}" get svc "${svc}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  # 只接受 IPv4：kubectl 输出异常（报错信息、空值、多行）时不要拼出垃圾 URL
  if ! printf '%s' "${cluster_ip}" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
    log "Service ${svc} 的 ClusterIP 取值异常（${cluster_ip:-空}），无法探测"
    dump_failure
    exit 1
  fi
  url="http://${cluster_ip}:${port}${path}"
  deadline=$(( $(date +%s) + TIMEOUT ))
  attempt=0
  last_error=""
  while :; do
    attempt=$(( attempt + 1 ))
    if last_error="$(curl -fsS --max-time 10 "${url}" 2>&1 >/dev/null)"; then
      log "健康探测通过（${url}，第 ${attempt} 次尝试）"
      break
    fi
    if [ "$(date +%s)" -ge "${deadline}" ]; then
      log "健康探测失败: ${url}（已尝试 ${attempt} 次，最后一次错误：${last_error:-无输出，可能返回非 2xx}）"
      dump_failure
      exit 1
    fi
    sleep 3
  done
fi

if [ -n "${PUBLIC_URL:-}" ]; then
  log "探测公网入口 ${PUBLIC_URL}"
  deadline=$(( $(date +%s) + TIMEOUT ))
  attempt=0
  last_error=""
  while :; do
    attempt=$(( attempt + 1 ))
    if last_error="$(curl -fsS --max-time 10 "${PUBLIC_URL}" 2>&1 >/dev/null)"; then
      log "公网探测通过（第 ${attempt} 次尝试）"
      break
    fi
    if [ "$(date +%s)" -ge "${deadline}" ]; then
      log "公网探测失败: ${PUBLIC_URL}（已尝试 ${attempt} 次，最后一次错误：${last_error:-无输出，可能返回非 2xx}；证书签发可能需要几十秒，可重跑部署）"
      exit 1
    fi
    sleep 5
  done
fi

log "当前工作负载状态"
kubectl -n "${NAMESPACE}" get pods -o wide 2>&1 | sed 's/^/    /'

log "完成"
