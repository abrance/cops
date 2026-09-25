#!/usr/bin/env bash
# cops 主机注册表查询工具。
#
# 读取仓库根的 hosts.yaml，给 CI 与本地排障提供统一的查询入口：
#
#   scripts/hosts.sh targets                列出所有主机名
#   scripts/hosts.sh <主机> drivers         该主机允许的部署驱动（空格分隔，如 "compose native"）
#   scripts/hosts.sh <主机> secret <键>     该主机某个凭据对应的 GitHub Secrets 名字
#                                           键：host | user | key | port | known_hosts
#   scripts/hosts.sh <主机> secrets         输出五行 "<键>=<Secrets 名字>"
#   scripts/hosts.sh check                  校验注册表结构（缺字段/未知字段/重复主机则失败）
#
# 为什么不用 YAML 解析库：部署链路（CI 的 resolve、部署 job）不希望多一个运行时依赖。
# hosts.yaml 的结构由本仓库自己维护，形状固定，因此这里用 awk 严格解析，并靠 `check`
# 模式把结构走样（缩进、字段名写错）变成显式失败，而不是静默取到空值。
set -euo pipefail

REPO_ROOT="${COPS_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HOSTS_FILE="${REPO_ROOT}/hosts.yaml"
SECRET_KEYS="host user key port known_hosts"

if [ ! -f "${HOSTS_FILE}" ]; then
  echo "找不到主机注册表 ${HOSTS_FILE}" >&2
  exit 1
fi

# 解析成 TSV：主机名 <TAB> drivers <TAB> host <TAB> user <TAB> key <TAB> port <TAB> known_hosts
# 解析不了的形状（未知字段、重复主机）直接报错退出。
parse_hosts() {
  awk -v secret_keys="${SECRET_KEYS}" '
    BEGIN {
      n = split(secret_keys, keys, " ")
      in_hosts = 0
      index_ = 0
      problems = 0
    }
    function flush(   i) {
      if (name == "") return
      if (drivers == "") { printf "hosts.yaml: 主机 %s 缺少 drivers\n", name > "/dev/stderr"; problems++ }
      else {
        m = split(drivers, dv, " ")
        for (i = 1; i <= m; i++) {
          if (dv[i] != "compose" && dv[i] != "native" && dv[i] != "k8s") {
            printf "hosts.yaml: 主机 %s 的 drivers 含未知驱动 %s\n", name, dv[i] > "/dev/stderr"; problems++
          }
        }
      }
      for (i = 1; i <= n; i++) {
        if (secrets[keys[i]] == "") { printf "hosts.yaml: 主机 %s 缺少 secrets.%s\n", name, keys[i] > "/dev/stderr"; problems++ }
      }
      printf "%s\t%s", name, drivers
      for (i = 1; i <= n; i++) printf "\t%s", secrets[keys[i]]
      printf "\n"
    }
    /^hosts:[[:space:]]*$/ { in_hosts = 1; next }
    /^[^[:space:]]/ { if (in_hosts) { flush(); in_hosts = 0 } ; next }
    !in_hosts { next }
    # 两位缩进：主机名
    /^  [A-Za-z0-9._-]+:[[:space:]]*$/ {
      flush()
      name = $1; sub(/:$/, "", name)
      if (seen[name]++) { printf "hosts.yaml: 主机 %s 重复定义\n", name > "/dev/stderr"; problems++ }
      drivers = ""
      delete secrets
      in_secrets = 0
      next
    }
    # 四位缩进：driver / notes / secrets
    /^    [A-Za-z0-9._-]+:/ {
      key = $1; sub(/:$/, "", key)
      value = $0; sub(/^[[:space:]]*[A-Za-z0-9._-]+:[[:space:]]*/, "", value)
      if (key == "drivers") { drivers = value; in_secrets = 0 }
      else if (key == "notes") { in_secrets = 0 }
      else if (key == "secrets") { in_secrets = 1 }
      else { printf "hosts.yaml: 主机 %s 出现未知字段 %s\n", name, key > "/dev/stderr"; problems++ }
      next
    }
    # 六位缩进：secrets 下的键
    /^      [A-Za-z0-9._-]+:/ {
      if (!in_secrets) { printf "hosts.yaml: 第 %d 行的字段不在 secrets 段内\n", NR > "/dev/stderr"; problems++; next }
      key = $1; sub(/:$/, "", key)
      value = $0; sub(/^[[:space:]]*[A-Za-z0-9._-]+:[[:space:]]*/, "", value)
      found = 0
      for (i = 1; i <= n; i++) if (keys[i] == key) found = 1
      if (!found) { printf "hosts.yaml: 主机 %s 的 secrets 出现未知键 %s\n", name, key > "/dev/stderr"; problems++; next }
      secrets[key] = value
      next
    }
    END {
      flush()
      if (problems > 0) exit 1
      if (name == "" && !seen[name]) { if (NR == 0) exit 1 }
    }
  ' "${HOSTS_FILE}"
}

all_hosts() { parse_hosts; }

lookup() {
  local want_host="$1" field="$2" key="$3"
  local found=0
  while IFS=$'\t' read -r name drivers s_host s_user s_key s_port s_known; do
    [ "${name}" = "${want_host}" ] || continue
    found=1
    case "${field}" in
      drivers) printf '%s\n' "${drivers}" ;;
      secret)
        case "${key}" in
          host) printf '%s\n' "${s_host}" ;;
          user) printf '%s\n' "${s_user}" ;;
          key) printf '%s\n' "${s_key}" ;;
          port) printf '%s\n' "${s_port}" ;;
          known_hosts) printf '%s\n' "${s_known}" ;;
          *) echo "未知凭据键 ${key}（可用：${SECRET_KEYS}）" >&2; exit 2 ;;
        esac
        ;;
      secrets)
        printf '%s=%s\n' host "${s_host}" user "${s_user}" key "${s_key}" port "${s_port}" known_hosts "${s_known}"
        ;;
    esac
  done < <(all_hosts)
  if [ "${found}" -eq 0 ]; then
    echo "hosts.yaml 里没有主机 ${want_host}" >&2
    exit 1
  fi
}

cmd="${1:-}"
case "${cmd}" in
  targets)
    all_hosts | cut -f1
    ;;
  check)
    all_hosts >/dev/null
    echo "hosts.yaml 校验通过：$(all_hosts | cut -f1 | paste -sd' ' -)"
    ;;
  ""|-h|--help)
    sed -n 's/^# \{0,1\}//p' "${BASH_SOURCE[0]}" | sed -n '1,20p'
    exit 0
    ;;
  *)
    [ $# -ge 2 ] || { echo "用法: hosts.sh <主机> <drivers|secret|secrets>" >&2; exit 2; }
    lookup "${cmd}" "${2}" "${3:-}"
    ;;
esac
