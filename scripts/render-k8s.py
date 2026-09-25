#!/usr/bin/env python3
"""k8s 单元的期望状态渲染器：把 k8s.yaml 里的 ${VAR} 用 .env 的值替换。

用法：
    scripts/render-k8s.py apps/model-ocr > /tmp/rendered.yaml

由 CI 在 runner 侧执行（渲染结果随单元目录一起同步到目标主机，主机只负责
kubectl apply）。本地排障时也可以直接跑，`docker compose config` 那种角色。

为什么要自己渲染，而不是 envsubst：
  1. envsubst 对未定义的变量会静默替换成空串——会把端口、镜像 tag 打成空值，
     直到 apply 到集群才报错。这里改为显式失败并列出缺失的变量名。
  2. envsubst 依赖 gettext，CI runner 上不保证存在；python3 一定有。

校验（全部通过才输出，任何一条不过就非零退出）：
  - .env 可解析（KEY=VALUE，支持 # 注释与成对引号）
  - k8s.yaml 里引用的每个 ${VAR} 都在 .env 中有定义
  - 每个 YAML 文档都含 apiVersion 与 kind（拦"文档数/结构写错"这类错误）
  - 渲染结果里不残留 ${...}（例如 ${VAR:-默认值} 这种 bash 语法，本渲染器不支持）
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

VAR_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")
LEFTOVER_RE = re.compile(r"\$\{")


def parse_env(env_file: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for lineno, raw in enumerate(env_file.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :]
        if "=" not in line:
            raise SystemExit(f"{env_file}:{lineno}: 不是 KEY=VALUE 形式：{raw!r}")
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            raise SystemExit(f"{env_file}:{lineno}: 变量名非法：{key!r}")
        values[key] = value
    return values


def render(unit_dir: Path) -> str:
    env_file = unit_dir / ".env"
    manifest = unit_dir / "k8s.yaml"
    if not env_file.is_file():
        raise SystemExit(f"缺少 {env_file}（k8s.yaml 的变量来源）")
    if not manifest.is_file():
        raise SystemExit(f"缺少 {manifest}")

    values = parse_env(env_file)
    source = manifest.read_text(encoding="utf-8")

    missing: dict[str, list[int]] = {}
    for lineno, line in enumerate(source.splitlines(), 1):
        for name in VAR_RE.findall(line):
            if name not in values:
                missing.setdefault(name, []).append(lineno)
    if missing:
        detail = "、".join(f"${{{n}}}（第 {','.join(map(str, ls))} 行）" for n, ls in sorted(missing.items()))
        raise SystemExit(
            f"{manifest} 引用了 .env 里没有定义的变量：{detail}\n"
            f"请在 {env_file} 中补上，或从 k8s.yaml 里删掉该引用。"
        )

    rendered = VAR_RE.sub(lambda m: values[m.group(1)], source)

    leftovers = [i for i, line in enumerate(rendered.splitlines(), 1) if LEFTOVER_RE.search(line)]
    if leftovers:
        raise SystemExit(
            f"{manifest} 渲染后仍残留 ${{...}}（第 {','.join(map(str, leftovers))} 行）："
            "本渲染器只支持 ${VAR} 形式，不支持 ${VAR:-默认值} 等 bash 语法。"
        )

    # 结构检查：每个文档必须有 apiVersion 与 kind
    problems = []
    index = 0
    for chunk in re.split(r"(?m)^---[ \t]*$", rendered):
        if not chunk.strip():
            continue
        index += 1
        if not re.search(r"(?m)^apiVersion:", chunk):
            problems.append(f"第 {index} 个文档缺 apiVersion")
        if not re.search(r"(?m)^kind:", chunk):
            problems.append(f"第 {index} 个文档缺 kind")
    if index == 0:
        problems.append("没有任何 YAML 文档")
    if problems:
        raise SystemExit(f"{manifest} 结构检查未通过：" + "；".join(problems))

    return rendered


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[3].strip(), file=sys.stderr)
        return 2
    unit_dir = Path(argv[1])
    if not unit_dir.is_dir():
        raise SystemExit(f"找不到单元目录 {unit_dir}")
    sys.stdout.write(render(unit_dir))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
