#!/usr/bin/env python3
"""只放行白名单的 CONNECT/HTTP 代理，给 cloud3 的 lems 采集走境内出口用。

为什么自写而不是 squid/tinyproxy：cloud2 上没有免密 sudo（装不了包），
Docker Hub 的第三方镜像又被镜像源 403 挡掉。python:3.12-slim 本地已有，
标准库足够，且白名单是硬编码的 —— 不存在被配置成开放代理的可能。

白名单是**目的主机名**，不是 IP：源站 IP 会变，按域名判断才不会误杀。
不在白名单的请求一律 403 并打日志，不回包。
"""

import os
import socket
import socketserver
import sys
import threading
import time

ALLOW = os.environ.get("PROXY_ALLOW", "pm.gd.csg.cn").split(",")
ALLOW = {h.strip().lower() for h in ALLOW if h.strip()}
PORT = int(os.environ.get("PROXY_PORT", "3128"))
BIND = os.environ.get("PROXY_BIND", "0.0.0.0")
BUFSIZE = 65536
# 绑不上（mesh 网卡还没起来）的重试次数：60s 足够 easytier 启动，再多就是在等一个写错的地址
BIND_RETRIES = int(os.environ.get("PROXY_BIND_RETRIES", "12"))


def allowed(host: str) -> bool:
    host = host.lower().rstrip(".")
    return host in ALLOW


def log(msg: str) -> None:
    print(f"[proxy] {msg}", flush=True)


def local_addrs() -> list:
    """本机 IPv4 地址，仅用于绑定失败时把「实际有什么」打进错误信息。

    镜像里没有 iproute2（python:3.12-slim），所以先试 `ip`，退到 /proc/net/fib_trie。
    network_mode: host 下 /proc 反映的是宿主路由表，地址与宿主一致。
    """
    try:
        import subprocess

        out = subprocess.run(["ip", "-4", "-o", "addr"], capture_output=True, text=True, timeout=5).stdout
        addrs = []
        for line in out.splitlines():
            parts = line.split()
            if len(parts) > 3:
                addrs.append(f"{parts[1]}={parts[3]}")
        if addrs:
            return addrs
    except Exception:
        pass
    try:
        # 只取 host LOCAL 条目：link/broadcast 行会把网段地址也列出来，容易误读。
        with open("/proc/net/fib_trie", encoding="ascii", errors="replace") as f:
            lines = f.read().splitlines()
        found = []
        for i, line in enumerate(lines):
            if "/32 host LOCAL" in line and i > 0:
                ip = lines[i - 1].split("|")[-1].strip().strip("+- ").strip()
                if ip.count(".") == 3:
                    found.append(ip)
        if found:
            return sorted(set(found))
    except Exception:
        pass
    return ["（无法读取网卡列表）"]


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        src = self.client_address[0]
        self.request.settimeout(30)
        try:
            head = b""
            while b"\r\n\r\n" not in head:
                chunk = self.request.recv(BUFSIZE)
                if not chunk:
                    return
                head += chunk
                if len(head) > 65536:
                    return
            line = head.split(b"\r\n", 1)[0].decode("latin-1")
            parts = line.split()
            if len(parts) < 3:
                return
            method, target, ver = parts[0], parts[1], parts[2]

            if method.upper() == "CONNECT":
                host, _, port = target.partition(":")
                port = int(port or 443)
            else:
                # 明文 HTTP 代理：target 是绝对 URI
                from urllib.parse import urlsplit

                u = urlsplit(target)
                host, port = u.hostname or "", u.port or 80

            if not allowed(host):
                log(f"DENY  {src} {method} {dest(host, port)}")
                self.request.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
                return

            upstream = socket.create_connection((host, port), timeout=20)
            try:
                if method.upper() == "CONNECT":
                    log(f"ALLOW {src} CONNECT {dest(host, port)}")
                    self.request.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                else:
                    log(f"ALLOW {src} {method} {dest(host, port)}")
                    rest = head.split(b"\r\n", 1)[1]
                    path = u.path or "/"
                    if u.query:
                        path += "?" + u.query
                    hdrs = rest.split(b"\r\n")
                    keep = [
                        h
                        for h in hdrs
                        if h
                        and not h.lower().startswith((b"proxy-connection", b"proxy-authorization"))
                    ]
                    upstream.sendall(
                        f"{method} {path} {ver}\r\n".encode("latin-1") + b"\r\n".join(keep) + b"\r\n\r\n"
                    )
                pipe(self.request, upstream)
            finally:
                upstream.close()
        except Exception as e:  # 客户端断开、上游超时都不该拖死进程
            log(f"ERR   {src}: {type(e).__name__}: {e}")


def dest(host: str, port: int) -> str:
    return f"{host}:{port}"


def pipe(a: socket.socket, b: socket.socket) -> None:
    def one_way(x, y):
        try:
            while True:
                data = x.recv(BUFSIZE)
                if not data:
                    break
                y.sendall(data)
        except Exception:
            pass
        finally:
            try:
                y.shutdown(socket.SHUT_WR)
            except Exception:
                pass

    t = threading.Thread(target=one_way, args=(b, a), daemon=True)
    t.start()
    one_way(a, b)
    t.join(timeout=5)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    if not ALLOW:
        sys.exit("PROXY_ALLOW 为空，拒绝启动（否则就是开放代理）")
    # 绑定的是 mesh 网卡地址（easytier tun0）。容器随 docker 自启，但 tun0 可能要更晚
    # 才出现；先重试等它（60s），仍然绑不上就**退出**而不是永远重试：
    # 地址写错时这里会每 5s 打一行日志，docker 侧看是「一直在跑」，而 lems 侧只是
    # 采集 failed/network —— 与源站故障无法区分。宁可让容器明确 exit。
    for attempt in range(1, BIND_RETRIES + 1):
        try:
            srv = Server((BIND, PORT), Handler)
            break
        except OSError as e:
            log(f"绑定 {BIND}:{PORT} 失败（{e}）第 {attempt}/{BIND_RETRIES} 次，5s 后重试")
            time.sleep(5)
    else:
        sys.exit(
            f"绑定 {BIND}:{PORT} 连续 {BIND_RETRIES} 次失败，地址不存在于本机网卡。\n"
            f"  两处必须同时改：\n"
            f"    apps/gdpm-proxy/compose.yaml  environment.PROXY_BIND（本进程监听 {BIND}）\n"
            f"    apps/lems-cloud3/.env         PROXY_URL（lems 连的是这个地址）\n"
            f"  当前网卡地址：" + ", ".join(local_addrs()) + "\n"
            f"  PR 阶段由 scripts/check-mesh-consistency.sh 拦这一类不一致。"
        )
    log(f"listening on {BIND}:{PORT}, allow={sorted(ALLOW)}")
    srv.serve_forever()
