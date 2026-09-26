#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""MClaw 远程终端连接器
通过 Cloudflare Tunnel 连接部署了本配置包的服务器上的 ttyd Web 终端(协议: tsl0922/ttyd 1.7.x)。
纯 Python 标准库, 无任何第三方依赖; macOS / Linux 开箱即用。

用法:
  ./connect.sh 服务器名              交互式终端(配置读自同目录 connect.json)
  ./connect.sh 服务器名 "命令"       执行一条命令, 输出后退出
  ./connect.sh https://域名 用户 密码 [命令]
选项:
  --proxy URL    经 HTTP 代理连接(如 http://127.0.0.1:7897); 默认先直连, 失败自动回退代理
交互式快捷键:
  Ctrl-] 退出会话(远端进程继续运行); 其余按键全部透传给远端
"""
import base64
import json
import os
import re
import select
import signal
import socket
import ssl
import struct
import subprocess
import sys
import termios
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CTRL_CLOSE = 0x1D  # Ctrl-]


def eprint(*a):
    print(*a, file=sys.stderr)


def split_url(url):
    """解析 https://host[:port][/base] → scheme/host/port/base"""
    from urllib.parse import urlsplit
    u = urlsplit(url.rstrip("/"))
    scheme = u.scheme or "https"
    return {
        "scheme": scheme,
        "host": u.hostname,
        "port": u.port or (80 if scheme == "http" else 443),
        "base": u.path or "/terminal",
    }


def load_profile(name=None):
    path = os.path.join(HERE, "connect.json")
    if not os.path.exists(path):
        return None
    cfg = json.load(open(path))
    name = name or cfg.get("default")
    p = cfg.get("servers", {}).get(name)
    if not p:
        return None
    prof = split_url(p["url"])
    prof["auth"] = base64.b64encode(f"{p['user']}:{p['password']}".encode()).decode()
    prof["proxy"] = cfg.get("proxy") or None
    return prof


def parse_args():
    argv = sys.argv[1:]
    proxy = None
    if "--proxy" in argv:
        i = argv.index("--proxy")
        proxy = argv[i + 1]
        del argv[i:i + 2]
    if argv and "://" in argv[0]:
        if len(argv) < 3:
            eprint("用法: connect.py [https|http]://域名[:端口] 用户 密码 [命令]")
            sys.exit(2)
        prof = split_url(argv[0])
        prof["auth"] = base64.b64encode(f"{argv[1]}:{argv[2]}".encode()).decode()
        prof["proxy"] = proxy
        return prof, argv[3] if len(argv) > 3 else None
    prof = load_profile(argv[0] if argv else None)
    if not prof:
        eprint(f"connect.json 里找不到服务器配置(参数: {argv})")
        sys.exit(2)
    if proxy:
        prof["proxy"] = proxy
    return prof, argv[1] if len(argv) > 1 else None


def curl_token(prof):
    """取 ttyd CSRF token, 直连失败自动回退代理"""
    port = f":{prof['port']}" if prof["port"] not in (80, 443) else ""
    url = f"{prof.get('scheme', 'https')}://{prof['host']}{port}{prof['base']}/token"
    proxies = [prof.get("proxy")]
    if prof.get("proxy") != "http://127.0.0.1:7897":
        proxies.append("http://127.0.0.1:7897")  # 本机 Clash 兜底
    last = None
    for rnd in range(10):
        px = proxies[0] if rnd < 5 else (proxies[1] if len(proxies) > 1 else proxies[0])
        cmd = ["curl", "-s", "--max-time", "8", "-H", f"Authorization: Basic {prof['auth']}"]
        if px:
            cmd += ["-x", px]
        cmd.append(url)
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
            if r.stdout.strip().startswith("{"):
                return json.loads(r.stdout)["token"]
            last = r.stdout.strip()[:60] or "超时"
        except Exception as e:
            last = str(e)
        time.sleep(3)
    raise SystemExit(f"取 token 失败(线路不通?): {last}")


def tls_connect(prof, proxy):
    host, port = prof["host"], prof["port"]
    if prof.get("scheme") == "http":  # 本地/局域网明文, 不走代理
        return socket.create_connection((host, port), timeout=10)
    if proxy:
        ppx = proxy.replace("http://", "").split(":")
        raw = socket.create_connection((ppx[0], int(ppx[1])), timeout=10)
        raw.sendall(f"CONNECT {host}:{port} HTTP/1.1\r\nHost: {host}:{port}\r\n\r\n".encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            c = raw.recv(4096)
            if not c:
                raise ConnectionError("代理无响应")
            buf += c
        if b" 200" not in buf.split(b"\r\n", 1)[0]:
            raise ConnectionError("代理 CONNECT 被拒")
    else:
        raw = socket.create_connection((host, port), timeout=10)
    return ssl.create_default_context().wrap_socket(raw, server_hostname=host)


def send_ws(s, op, payload):
    n = len(payload)
    hdr = bytes([0x80 | op])
    if n < 126:
        hdr += bytes([0x80 | n])
    elif n < 65536:
        hdr += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        hdr += bytes([0x80 | 127]) + struct.pack(">Q", n)
    mask = os.urandom(4)
    s.sendall(hdr + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))


def ws_session(prof, token, size):
    """建立 ttyd WebSocket 会话(tty 子协议 + AuthToken 首帧), 带重试"""
    if os.environ.get("MCLAW_DEBUG"):
        with open("/tmp/mclaw_trace.log", "a") as f:
            f.write("ws_session begin\n")
    last = None
    for rnd in range(8):
        try:
            s = tls_connect(prof, prof.get("proxy"))
            key = base64.b64encode(os.urandom(16)).decode()
            req = (f"GET {prof['base']}/ws HTTP/1.1\r\nHost: {prof['host']}\r\n"
                   "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                   f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
                   "Sec-WebSocket-Protocol: tty\r\n"
                   f"Authorization: Basic {prof['auth']}\r\n"
                   f"Origin: https://{prof['host']}\r\nUser-Agent: mclaw-connect\r\n\r\n")
            s.sendall(req.encode())
            resp = b""
            s.settimeout(10)
            while b"\r\n\r\n" not in resp:
                c = s.recv(4096)
                if not c:
                    raise ConnectionError("握手断开")
                resp += c
            if b" 101 " not in resp.split(b"\r\n", 1)[0]:
                s.close()
                raise ConnectionError(resp.split(b"\r\n", 1)[0].decode(errors="replace"))
            hello = json.dumps({"AuthToken": token, "columns": size[0], "rows": size[1]}).encode()
            send_ws(s, 0x2, hello)
            if os.environ.get("MCLAW_DEBUG"):
                with open("/tmp/mclaw_trace.log", "a") as f:
                    f.write("ws_session OK\n")
            return s
        except Exception as e:
            last = e
            eprint(f"  连接重试 {rnd + 1}/8: {e}")
            time.sleep(3)
    raise SystemExit(f"无法建立会话: {last}")


def ws_send_input(s, data: bytes):
    send_ws(s, 0x2, b"0" + data)


def ws_resize(s, cols, rows):
    send_ws(s, 0x2, b"1" + json.dumps({"columns": cols, "rows": rows}).encode())


def ws_read_once(s, timeout):
    """读一帧, 返回 (kind, data); kind: out|title|prefs|ping|closed|timeout"""
    s.settimeout(timeout)
    try:
        hdr = recv_exact(s, 2)
    except (socket.timeout, TimeoutError):
        return "timeout", b""
    except (ConnectionError, OSError):
        return "closed", b""
    op = hdr[0] & 0x0F
    ln = hdr[1] & 0x7F
    off = 2
    if ln == 126:
        ln = struct.unpack(">H", recv_exact(s, 2))[0]
        off = 4
    elif ln == 127:
        ln = struct.unpack(">Q", recv_exact(s, 8))[0]
        off = 10
    payload = recv_exact(s, ln) if ln else b""
    if op == 0x9:  # ws ping -> pong
        send_ws(s, 0xA, payload)
        return "ping", b""
    if op == 0x8:
        return "closed", b""
    if op in (0x1, 0x2) and payload:
        cmd, data = payload[:1], payload[1:]
        if cmd == b"0":
            return "out", data
        if cmd == b"1":
            return "title", data
        if cmd == b"2":
            return "prefs", data
    return "ignore", b""


def recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        c = s.recv(n - len(buf))
        if not c:
            raise ConnectionError("连接被关闭")
        buf += c
    return buf


def run_exec(prof, command):
    token = curl_token(prof)
    s = ws_session(prof, token, (200, 50))
    time.sleep(0.8)
    ws_send_input(s, command.encode() + b"\n")
    out = bytearray()
    deadline = time.time() + 60
    idle = 0.0
    while time.time() < deadline:
        kind, data = ws_read_once(s, 2.0)
        if kind == "out":
            out += data
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
            idle = 0.0
            # 只认独立成行的标记(输入回显行也含标记文本, 但不在行首行尾)
            lines = [l.strip() for l in re.split(rb"[\r\n]+", bytes(out))]
            if b"===EXEC_DONE===" in lines:
                time.sleep(0.3)
                break
        elif kind == "closed":
            break
        elif kind == "timeout":
            idle += 2.0
            if out and idle >= 4.0:
                break
    s.close()
    print()


def run_interactive(prof):
    token = curl_token(prof)
    try:
        cols, rows = os.get_terminal_size()
    except OSError:
        cols, rows = 120, 40
    s = ws_session(prof, token, (cols, rows))
    eprint(f"已连接 {prof['host']} — Ctrl-] 退出, 其余按键透传")
    old = termios.tcgetattr(0)
    import tty as _tty
    _tty.setraw(0, termios.TCSANOW)  # TCSANOW: 不丢弃连接期间已敲入的按键(TCSAFLUSH 会冲掉)

    def on_winch(*_):
        try:
            c, r = os.get_terminal_size()
            ws_resize(s, c, r)
        except Exception:
            pass

    signal.signal(signal.SIGWINCH, on_winch)
    last_io = time.time()
    dbg = os.environ.get("MCLAW_DEBUG")
    dbglog = open("/tmp/mclaw_debug.log", "ab") if dbg else None

    def dlog(msg):
        if dbglog:
            dbglog.write(f"[{time.time():.3f}] {msg}\n".encode())
            dbglog.flush()

    if dbg:
        eprint("[debug] raw 模式已开, 进入循环")
    dlog(f"loop start, fd0={os.fstat(0)}, tty={os.isatty(0)}")
    n = 0
    try:
        while True:
            rl, _, _ = select.select([0, s], [], [], 30.0)
            n += 1
            dlog(f"loop{n} rl={['fd0' if x == 0 else 'sock' for x in rl]}")
            now = time.time()
            if now - last_io > 25:  # 保活, 防 Cloudflare 100s 空闲断链
                send_ws(s, 0x9, b"ka")
                last_io = now
            if s in rl:
                kind, data = ws_read_once(s, 1.0)
                dlog(f"frame kind={kind} len={len(data)} head={data[:40]!r}")
                if kind == "out":
                    sys.stdout.buffer.write(data)
                    sys.stdout.buffer.flush()
                    last_io = now
                elif kind == "closed":
                    if os.environ.get("MCLAW_DEBUG"):
                        eprint("\r\n[debug] socket closed by remote")
                    eprint("\r\n[连接已断开]")
                    break
            if 0 in rl:
                data = os.read(0, 4096)
                dlog(f"stdin={data!r}")
                if os.environ.get("MCLAW_DEBUG"):
                    eprint(f"\r\n[debug] stdin={data!r}")
                if not data or CTRL_CLOSE in data:
                    eprint("\r\n[已退出, 远端会话仍在运行]")
                    break
                ws_send_input(s, data)
                last_io = now
    finally:
        termios.tcsetattr(0, termios.TCSADRAIN, old)
        try:
            s.close()
        except Exception:
            pass


def main():
    if os.environ.get("MCLAW_DEBUG"):
        with open("/tmp/mclaw_trace.log", "a") as f:
            f.write(f"main entered argv={sys.argv}\n")
    prof, command = parse_args()
    if command:
        command = f"{command}; echo ===EXEC_DONE==="
        run_exec(prof, command)
    else:
        run_interactive(prof)


if __name__ == "__main__":
    main()
