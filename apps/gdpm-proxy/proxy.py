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


def allowed(host: str) -> bool:
    host = host.lower().rstrip(".")
    return host in ALLOW


def log(msg: str) -> None:
    print(f"[proxy] {msg}", flush=True)


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
    # 才出现；绑不上就重试，而不是让容器进入 restart 循环等 docker 重拉。
    while True:
        try:
            srv = Server((BIND, PORT), Handler)
            break
        except OSError as e:
            log(f"绑定 {BIND}:{PORT} 失败（{e}），5s 后重试")
            time.sleep(5)
    log(f"listening on {BIND}:{PORT}, allow={sorted(ALLOW)}")
    srv.serve_forever()
