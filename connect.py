#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Cloud Remote Tunnel 连接器
通过 Cloudflare Tunnel 连接部署了本配置包的服务器上的 ttyd Web 终端(协议: tsl0922/ttyd 1.7.x)。
纯 Python 标准库, 无任何第三方依赖; macOS / Linux 开箱即用。

用法:
  ./connect.sh 服务器名                 交互式终端(配置读自 connect.json)
  ./connect.sh 服务器名 "命令"           执行一条命令, 输出后退出(远端退出码透传)
  ./connect.sh https://域名 用户 密码 [命令]    纯命令行直连

  环境变量免密模式 (适合 AI / CI / 脚本自动化调用, 无需 connect.json):
    TUNNEL_URL=https://域名 TUNNEL_USER=用户 TUNNEL_PASSWORD=密码 ./connect.sh "命令"
    TUNNEL_URL=... TUNNEL_USER=... TUNNEL_PASSWORD=... ./connect.sh --add-server 名称   # 登记进 connect.json

  ./connect.sh --check [服务器名 | URL 用户 密码]   连通性自检 (token 获取 + WebSocket 握手)
  ./connect.sh --list                               列出 connect.json 中已登记的服务器

文件传输 (基于 base64 经终端会话传输, 无需额外端口/服务):
  ./connect.sh 服务器名 --upload 本地文件 [远端路径]    上传 (远端路径省略则传到 ~/)
  ./connect.sh 服务器名 --download 远端路径 [本地路径]  下载 (本地路径省略则用同名文件)

选项:
  --proxy URL      经 HTTP 代理连接(如 http://127.0.0.1:7897)
  --no-proxy       禁用一切代理(含默认兜底), 强制直连
  --timeout N      命令模式超时秒数(默认 60)
  --json           以 JSON 输出结果(命令模式含输出与退出码; 适合 AI 解析)
  --config PATH    指定 connect.json 路径
  --server NAME    显式按名称使用 connect.json 中的服务器
  --url/--user/--password   与 --add-server 搭配的显式值
  --chunk N        文件传输分块大小(字节, 默认 2048; 终端单行长度受限, 不宜过大)

环境变量:
  TUNNEL_URL / TUNNEL_USER / TUNNEL_PASSWORD   免密直连凭据(优先级: 命令参数 > 环境变量 > connect.json)
  TUNNEL_PROXY                                  代理地址(等价于 --proxy)
  CRT_PROXY_FALLBACK                            直连失败时的兜底代理(默认 http://127.0.0.1:7897, 置空则禁用)
  CRT_CONFIG                                    connect.json 路径

退出码: 0 成功 | 1 连接失败 | 2 用法/配置错误 | 命令模式透传远端退出码 (超时 124)
交互式快捷键: Ctrl-] 退出会话(远端进程继续运行); 其余按键全部透传给远端
"""
import base64
import json
import os
import re
import select
import shlex
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
DEFAULT_FALLBACK_PROXY = "http://127.0.0.1:7897"
# 连接阶段(取 token + 建 WebSocket 会话)的默认总预算秒数, 可用
# CRT_CONNECT_TIMEOUT 覆盖; 实际取值还会被 --timeout 收紧。
CONNECT_BUDGET_DEFAULT = 12

USAGE = """\
Cloud Remote Tunnel 连接器

用法:
  connect.sh 服务器名                交互式终端(配置读自 connect.json)
  connect.sh 服务器名 "命令"          执行一条命令(远端退出码透传)
  connect.sh https://域名 用户 密码 [命令]    纯命令行直连
  connect.sh --check [目标...]        连通性自检
  connect.sh --list                   列出已登记服务器
  connect.sh --add-server 名称        从环境变量登记服务器到 connect.json

文件传输 (走终端会话, 适合中小文件):
  connect.sh 服务器名 --upload 本地文件 [远端路径]     上传(默认传到远端家目录同名)
  connect.sh 服务器名 --download 远端路径 [本地路径]   下载(默认存为本地同名文件)
  边界: 终端通道适合配置/日志/脚本等 4MB 以内文件;
        大文件请用 croc (P2P, 无需域名) 或 rsync 到自己的 VPS。
        --force 可强制尝试超过建议上限的文件。

环境变量免密模式 (AI / 脚本):
  TUNNEL_URL=... TUNNEL_USER=... TUNNEL_PASSWORD=... connect.sh "命令"

超时约定 (对 AI / CI 调用很重要):
  连接阶段(取 token + 建会话)默认最多 12 秒, 且不超过 --timeout;
  域名解析失败立即报错不再重试。因此不可达时是秒级失败 + 非 0 退出码,
  不会长时间挂着不动。需要放宽时设 CRT_CONNECT_TIMEOUT=秒数。

常用选项:
  --proxy URL / --no-proxy / --timeout N / --json / --config PATH / --server NAME
  --chunk N   分块字节数(默认 8192)
  --batch N   每批块数(默认 4; 往返延迟是主要成本)
  --force     跳过文件体积建议上限
"""


def eprint(*a):
    print(*a, file=sys.stderr)


def debug_enabled():
    return bool(os.environ.get("CRT_DEBUG") or os.environ.get("MCLAW_DEBUG"))


def split_url(url):
    """解析 https://host[:port][/base] → scheme/host/port/base"""
    from urllib.parse import urlsplit
    u = urlsplit(url.rstrip("/"))
    scheme = u.scheme or "https"
    if scheme not in ("http", "https"):
        raise SystemExit(f"仅支持 http/https 协议: {url}")
    return {
        "scheme": scheme,
        "host": u.hostname,
        "port": u.port or (80 if scheme == "http" else 443),
        "base": u.path or "/terminal",
    }


def config_path(opts):
    return opts.get("config") or os.environ.get("CRT_CONFIG") or os.path.join(HERE, "connect.json")


def load_profile(name, opts):
    """从 connect.json 载入服务器配置; 找不到返回 None"""
    path = config_path(opts)
    if not os.path.exists(path):
        return None
    try:
        with open(path) as f:
            cfg = json.load(f)
    except Exception:
        eprint(f"⚠️  配置文件无法解析: {path}")
        return None
    name = name or cfg.get("default")
    if not name:
        return None
    p = (cfg.get("servers") or {}).get(name)
    if not p:
        return None
    prof = split_url(p["url"])
    prof["auth"] = base64.b64encode(f"{p.get('user', '')}:{p.get('password', '')}".encode()).decode()
    prof["proxy"] = p.get("proxy") or cfg.get("proxy") or None
    if "proxy_fallback" in p:
        prof["proxy_fallback"] = p["proxy_fallback"]
    elif "proxy_fallback" in cfg:
        prof["proxy_fallback"] = cfg["proxy_fallback"]
    return prof


def env_profile(opts):
    """从 TUNNEL_URL / TUNNEL_USER / TUNNEL_PASSWORD 环境变量构造配置 (免密模式)"""
    url = opts.get("url") or os.environ.get("TUNNEL_URL")
    user = opts.get("user") or os.environ.get("TUNNEL_USER")
    password = opts.get("password") or os.environ.get("TUNNEL_PASSWORD")
    if not (url and user and password):
        return None
    prof = split_url(url)
    prof["auth"] = base64.b64encode(f"{user}:{password}".encode()).decode()
    prof["proxy"] = None
    return prof


def proxy_order(prof, opts):
    """返回代理尝试顺序: 首选代理(可为 None=直连) → 兜底代理"""
    if opts.get("no_proxy"):
        return [None]
    primary = (opts.get("proxy") or os.environ.get("TUNNEL_PROXY")
               or prof.get("proxy") or prof.get("_proxy_used") or None)
    order = [primary]
    fb = os.environ.get("CRT_PROXY_FALLBACK")
    if fb is None:
        fb = prof.get("proxy_fallback")
        if fb is None:
            fb = DEFAULT_FALLBACK_PROXY
    if fb and fb != primary:
        order.append(fb)
    return order


def parse_args():
    argv = sys.argv[1:]
    opts = {"proxy": None, "no_proxy": False, "timeout": 60, "json": False, "check": False,
            "add_server": None, "list": False, "config": None, "server": None,
            "url": None, "user": None, "password": None, "set_default": False, "help": False,
            "upload": None, "download": None, "chunk": 8192, "batch": 4, "force": False}
    rest = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--proxy" and i + 1 < len(argv):
            opts["proxy"] = argv[i + 1]; i += 2
        elif a == "--timeout" and i + 1 < len(argv):
            opts["timeout"] = argv[i + 1]; i += 2
        elif a == "--config" and i + 1 < len(argv):
            opts["config"] = argv[i + 1]; i += 2
        elif a == "--server" and i + 1 < len(argv):
            opts["server"] = argv[i + 1]; i += 2
        elif a == "--add-server" and i + 1 < len(argv):
            opts["add_server"] = argv[i + 1]; i += 2
        elif a == "--url" and i + 1 < len(argv):
            opts["url"] = argv[i + 1]; i += 2
        elif a == "--user" and i + 1 < len(argv):
            opts["user"] = argv[i + 1]; i += 2
        elif a == "--password" and i + 1 < len(argv):
            opts["password"] = argv[i + 1]; i += 2
        elif a == "--upload" and i + 1 < len(argv):
            opts["upload"] = argv[i + 1]; i += 2
        elif a == "--download" and i + 1 < len(argv):
            opts["download"] = argv[i + 1]; i += 2
        elif a == "--chunk" and i + 1 < len(argv):
            try:
                opts["chunk"] = max(4096, int(argv[i + 1]))
            except ValueError:
                eprint("--chunk 需要正整数"); sys.exit(2)
            i += 2
        elif a == "--batch" and i + 1 < len(argv):
            try:
                opts["batch"] = max(1, min(64, int(argv[i + 1])))
            except ValueError:
                eprint("--batch 需要正整数"); sys.exit(2)
            i += 2
        elif a == "--force":
            opts["force"] = True; i += 1
        elif a == "--json":
            opts["json"] = True; i += 1
        elif a == "--check":
            opts["check"] = True; i += 1
        elif a == "--list":
            opts["list"] = True; i += 1
        elif a == "--no-proxy":
            opts["no_proxy"] = True; i += 1
        elif a == "--set-default":
            opts["set_default"] = True; i += 1
        elif a in ("-h", "--help"):
            opts["help"] = True; i += 1
        else:
            rest.append(a); i += 1
    return opts, rest


def build_profile(opts, rest):
    """统一解析连接目标, 返回 (prof, command)
    优先级: --server NAME > 显式 URL > connect.json 名称 > 环境变量免密模式(剩余参数视为命令)
    """
    if opts.get("server"):
        prof = load_profile(opts["server"], opts)
        if not prof:
            eprint(f"connect.json 里找不到服务器: {opts['server']}")
            sys.exit(2)
        return prof, (" ".join(rest) or None)

    if rest and "://" in rest[0]:
        url = rest[0]
        args = rest[1:]
        user = password = None
        cmd = None
        if len(args) >= 2:
            user, password = args[0], args[1]
            cmd = " ".join(args[2:]) or None
        else:
            user = opts.get("user") or os.environ.get("TUNNEL_USER")
            password = opts.get("password") or os.environ.get("TUNNEL_PASSWORD")
            cmd = " ".join(args) or None
            if not (user and password):
                eprint("用法: connect.sh [https|http]://域名[:端口] 用户 密码 [命令]")
                eprint("     或: TUNNEL_USER=... TUNNEL_PASSWORD=... connect.sh URL [命令]")
                sys.exit(2)
        prof = split_url(url)
        prof["auth"] = base64.b64encode(f"{user}:{password}".encode()).decode()
        prof["proxy"] = None
        return prof, cmd

    name = rest[0] if rest else None
    if name:
        prof = load_profile(name, opts)
        if prof:
            return prof, (" ".join(rest[1:]) or None)

    prof = env_profile(opts)
    if prof is not None:
        return prof, ((" ".join(rest) or None) if name else None)

    eprint("找不到服务器配置: 可用 connect.json / --server 名称 / TUNNEL_URL 环境变量 / 命令行 URL")
    sys.exit(2)


def connect_budget(opts):
    """连接阶段(取 token + 建 WebSocket 会话)的总预算秒数。

    默认 12 秒, 且不超过 --timeout。可用 CRT_CONNECT_TIMEOUT 覆盖。
    为什么必须限时: 代理/网关"接受连接但不回包"时, 原先按次数重试
    (取 token 10 轮 + 建会话 8 轮, 各带 sleep) 会挂到 100 秒以上且
    全程无输出 —— 对 AI/CI 调用来说, 挂死比报错难处理得多。
    """
    budget = CONNECT_BUDGET_DEFAULT
    raw = os.environ.get("CRT_CONNECT_TIMEOUT")
    if raw:
        try:
            v = float(raw)
            if v > 0:
                budget = v
        except ValueError:
            pass
    try:
        t = float(opts.get("timeout") or 0)
    except (TypeError, ValueError):
        t = 0
    if t > 0:
        budget = min(budget, t)
    return int(budget) if budget == int(budget) else budget


def connect_deadline(opts):
    """连接阶段的共享截止时间(monotonic 秒)。

    同一次调用的"取 token"与"建会话"共用同一个截止时间, 否则两个阶段
    各自重试会把总耗时翻倍。
    """
    d = opts.get("_connect_deadline")
    if d is None:
        d = time.monotonic() + connect_budget(opts)
        opts["_connect_deadline"] = d
    return d


def remaining_budget(opts):
    """连接阶段剩余秒数; <=0 表示预算已耗尽"""
    return connect_deadline(opts) - time.monotonic()


def curl_token(prof, opts):
    """取 ttyd CSRF token; 按代理顺序重试 (直连失败自动回退兜底代理)

    在 connect_budget() 预算内重试, 每次 curl 的 --max-time 也按剩余预算收紧,
    预算耗尽立即报错, 不再继续等待。
    """
    port = f":{prof['port']}" if prof["port"] not in (80, 443) else ""
    url = f"{prof.get('scheme', 'https')}://{prof['host']}{port}{prof['base']}/token"
    order = proxy_order(prof, opts)
    last = None
    rnd = 0
    dns_failed = False
    while True:
        remaining = remaining_budget(opts)
        if remaining <= 1.0:
            break
        px = order[0] if rnd < 5 else order[min(1, len(order) - 1)]
        cap = max(1, min(8, int(remaining)))
        cmd = ["curl", "-s", "--max-time", str(cap), "-H", f"Authorization: Basic {prof['auth']}"]
        if px:
            cmd += ["-x", px]
        cmd.append(url)
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=cap + 2)
            if r.stdout.strip().startswith("{"):
                prof["_proxy_used"] = px
                return json.loads(r.stdout)["token"]
            # curl 退出码 6 = 域名无法解析。同一进程内重试同一个域名不会变好,
            # 立即失败比把预算耗光更快给出可操作的错误。
            if r.returncode == 6:
                last = f"域名无法解析: {prof['host']}"
                dns_failed = True
                break
            last = r.stdout.strip()[:60] or "超时"
        except Exception as e:
            last = str(e)
        rnd += 1
        # 只剩很少预算时不再退避, 立即进入下一轮/报错
        if remaining_budget(opts) > 3.0:
            time.sleep(2)
    if dns_failed:
        raise SystemExit(f"取 token 失败: {last} (检查域名拼写 / DNS / hosts)")
    hint = "；试加 --no-proxy 排除代理因素" if [p for p in order if p] else ""
    raise SystemExit(
        f"取 token 失败(线路不通?): {last} — 连接阶段 {connect_budget(opts):.0f}s 预算已用尽{hint}"
    )


def tls_connect(prof, proxy, timeout=10):
    host, port = prof["host"], prof["port"]
    if prof.get("scheme") == "http":  # 本地/局域网明文, 不走代理
        return socket.create_connection((host, port), timeout=timeout)
    if proxy:
        ppx = proxy.replace("http://", "").split(":")
        raw = socket.create_connection((ppx[0], int(ppx[1])), timeout=timeout)
        raw.settimeout(timeout)
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
        raw = socket.create_connection((host, port), timeout=timeout)
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


def ws_session(prof, token, size, opts):
    """建立 ttyd WebSocket 会话(tty 子协议 + AuthToken 首帧), 带代理顺序重试

    与 curl_token 共用同一个连接预算: 预算内重试, 耗尽立即报错。
    """
    if debug_enabled():
        with open("/tmp/crt_trace.log", "a") as f:
            f.write("ws_session begin\n")
    order = proxy_order(prof, opts)
    last = None
    rnd = 0
    while True:
        remaining = remaining_budget(opts)
        if remaining <= 1.0:
            break
        px = order[0] if rnd < 4 else order[min(1, len(order) - 1)]
        try:
            per_try = min(10, max(1, remaining))
            s = tls_connect(prof, px, timeout=per_try)
            key = base64.b64encode(os.urandom(16)).decode()
            req = (f"GET {prof['base']}/ws HTTP/1.1\r\nHost: {prof['host']}\r\n"
                   "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                   f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
                   "Sec-WebSocket-Protocol: tty\r\n"
                   f"Authorization: Basic {prof['auth']}\r\n"
                   f"Origin: https://{prof['host']}\r\nUser-Agent: crt-connect\r\n\r\n")
            s.sendall(req.encode())
            resp = b""
            s.settimeout(per_try)
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
            if debug_enabled():
                with open("/tmp/crt_trace.log", "a") as f:
                    f.write("ws_session OK\n")
            return s
        except Exception as e:
            last = e
            eprint(f"  连接重试: {e}")
            if remaining_budget(opts) > 3.0:
                time.sleep(2)
        rnd += 1
    raise SystemExit(f"无法建立会话: {last} — 连接阶段 {connect_budget(opts):.0f}s 预算已用尽")


def ws_send_input(s, data: bytes):
    send_ws(s, 0x2, b"0" + data)


def ws_resize(s, cols, rows):
    send_ws(s, 0x2, b"1" + json.dumps({"columns": cols, "rows": rows}).encode())


def ws_read_once(s, timeout):
    """读一帧, 返回 (kind, data); kind: out|title|prefs|ping|closed|timeout

    注意: 帧头/payload 必须完整读到才能继续, 半帧会导致整个 WebSocket
    流错位。因此超时只作为"暂时没数据"的信号, 一旦开始读某一帧就
    必须把它读完 (用较长的兜底超时), 否则后续所有帧都会解析错。
    """
    s.settimeout(timeout)
    try:
        hdr = recv_exact(s, 2, timeout)
    except (socket.timeout, TimeoutError):
        return "timeout", b""
    except (ConnectionError, OSError):
        return "closed", b""
    op = hdr[0] & 0x0F
    ln = hdr[1] & 0x7F
    # 一旦帧头到手, 后续读取给足时间 (30s), 避免半帧造成流错位
    hard_deadline = 30.0
    try:
        if ln == 126:
            ln = struct.unpack(">H", recv_exact(s, 2, hard_deadline))[0]
        elif ln == 127:
            ln = struct.unpack(">Q", recv_exact(s, 8, hard_deadline))[0]
        payload = recv_exact(s, ln, hard_deadline) if ln else b""
    except (socket.timeout, TimeoutError):
        return "closed", b""
    except (ConnectionError, OSError):
        return "closed", b""
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


def recv_exact(s, n, timeout=None):
    """精确读取 n 字节; 可指定整体超时, 超时抛 socket.timeout
    (调用方需保证: 要么读满, 要么视为连接不可用, 不能留下半帧)
    """
    buf = b""
    deadline = (time.time() + timeout) if timeout else None
    while len(buf) < n:
        if deadline:
            remain = deadline - time.time()
            if remain <= 0:
                raise socket.timeout("recv_exact timeout")
            s.settimeout(remain)
        c = s.recv(n - len(buf))
        if not c:
            raise ConnectionError("连接被关闭")
        buf += c
    return buf


# ---------------------------------------------------------------
# 命令模式 (run_exec): 支持退出码透传 / JSON 输出 / 输出净化
# ---------------------------------------------------------------
_EXEC_NOISE = {
    b"__crt_rc=$?",
    b'echo "===EXIT_CODE:$__crt_rc==="',
    b'echo "===EXEC_DONE==="',
}


def _filter_exec_chunk(data, state):
    """按行净化输出: 剥离内部包装标记, 捕获退出码与完成标记
    state: {"partial": bytes, "rc": int|None, "done": bool}
    注意: 输入回显行同时包含两个标记文本, 必须先剔除回显行再做标记匹配。
    """
    buf = state["partial"] + data
    lines = buf.split(b"\n")
    state["partial"] = lines.pop()
    out = []
    for ln in lines:
        core = ln[:-1] if ln.endswith(b"\r") else ln
        stripped = core.strip()
        if b"__crt_rc=$?;" in stripped:  # 输入回显行, 丢弃
            continue
        if b"===EXEC_DONE===" in stripped:
            state["done"] = True
            continue
        m = re.search(rb"===EXIT_CODE:(\d+)===", stripped)
        if m:
            state["rc"] = int(m.group(1))
            continue
        if stripped in _EXEC_NOISE:
            continue
        out.append(ln + b"\n")
    return b"".join(out)


def wait_first_output(s, seconds=6.0, quiet=False):
    """等待首屏输出(如 shell 提示符), 避免命令发送过早; quiet=True 时不输出(JSON 模式)"""
    end = time.time() + seconds
    while time.time() < end:
        kind, data = ws_read_once(s, 0.5)
        if kind == "out":
            if not quiet:
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
            return True
        if kind == "closed":
            return False
    return False


def run_exec(prof, command, opts):
    """执行单条命令; 返回远端退出码 (超时 124, 连接失败抛 SystemExit)"""
    t0 = time.time()
    token = curl_token(prof, opts)
    s = ws_session(prof, token, (240, 60), opts)
    wait_first_output(s, 6.0, quiet=bool(opts.get("json")))

    # 单行包装: 用子 shell 包装命令, 使 exit/exec 等只影响子 shell, 退出码可被捕获
    cmd = command.strip()
    if cmd.endswith(";"):
        cmd = cmd[:-1]
    payload = ("( " + cmd + " ); __crt_rc=$?; printf '\\n===EXIT_CODE:%s===\\n' \"$__crt_rc\"; echo \"===EXEC_DONE===\"\n")
    ws_send_input(s, payload.encode())

    state = {"partial": b"", "rc": None, "done": False, "closed": False}
    collected = []
    deadline = time.time() + float(opts.get("timeout") or 60)
    idle = 0.0
    while time.time() < deadline:
        kind, data = ws_read_once(s, 2.0)
        if kind == "out":
            emit = _filter_exec_chunk(data, state)
            if emit:
                if opts.get("json"):
                    collected.append(emit)
                else:
                    sys.stdout.buffer.write(emit)
                    sys.stdout.buffer.flush()
            if state["done"] or state["rc"] is not None:
                time.sleep(0.2)
                break
            idle = 0.0
        elif kind == "closed":
            state["closed"] = True
            break
        elif kind == "timeout":
            idle += 2.0
            if (collected or state["partial"]) and idle >= 6.0:
                break

    tail = state["partial"]
    if tail:
        if opts.get("json"):
            collected.append(tail)
        else:
            sys.stdout.buffer.write(tail)
            sys.stdout.buffer.flush()

    try:
        s.close()
    except Exception:
        pass

    elapsed = time.time() - t0
    rc = state["rc"]
    timed_out = (not state["done"]) and rc is None and not state["closed"]

    if opts.get("json"):
        out_text = b"".join(collected).decode("utf-8", "replace")
        print(json.dumps({
            "ok": rc == 0,
            "exit_code": rc,
            "timeout": timed_out,
            "host": prof["host"],
            "seconds": round(elapsed, 2),
            "output": out_text,
        }, ensure_ascii=False))
    elif timed_out:
        eprint("[超时] 命令未在限定时间内完成")

    if rc is None:
        rc = 124 if timed_out else 1
    return rc


# ---------------------------------------------------------------
# 文件传输 (--upload / --download)
# ---------------------------------------------------------------
# 能力边界 (实测结论, 请务必先读):
#
#   ttyd 只提供终端字节流, 没有独立文件通道。这里复用同一条 WebSocket
#   会话, 用 base64 分块经终端写入/读出。优点: 远端零依赖 (只要 base64
#   和 shell)、不需要 sshd、不需要额外端口。
#
#   但 CF 隧道下实测: 单次往返约 0.5s, 且长时间连续写入终端会触发
#   TLS 读超时/字符丢失。因此本通道适合 **配置、日志、脚本、几十 MB 以内
#   的中小文件**; 实测 5MB 在公共 quick tunnel 上已不稳定。
#
#   大文件请走专用通道 (二选一):
#     * croc:  两端各装一个 9MB 单文件, croc send / croc <code>
#              (P2P 直连优先, 失败自动回落公共中继; 不需要域名)
#     * 你自己的 VPS + rsync/scp
#
#   这不是实现缺陷, 是 ttyd 协议的固有边界: 它设计给交互式终端, 不是
#   文件传输协议。诚实地划出边界, 比假装能传 100MB 更有用。
#
# 可靠性设计:
#   * 每批传输后回显确认标记, 避免终端丢字符导致的静默损坏;
#   * 传输结束校验大小, 不一致即失败;
#   * 失败立即中止并给出可操作的错误, 不写入半截文件。

_UP_BEGIN = "CRT_UP_BEGIN"
_UP_CHUNK_OK = "CRT_CHUNK_OK"
_UP_DONE = "CRT_UP_DONE"
_DL_BEGIN = "CRT_DL_BEGIN"
_DL_END = "CRT_DL_END"
_DL_ERR = "CRT_DL_ERR"

# 超过该体积直接拒绝并建议改用 croc, 避免用户等到超时才失败。
# 实测依据 (CF quick tunnel): 200KB 用 24.5s, 2MB 用 186s, 5MB 中途超时。
# 2MB 约 11KB/s; 取 4MB 作为保守上限 (~6 分钟), 再大应换专用通道。
SMALL_FILE_LIMIT = 4 * 1024 * 1024


def _read_until(s, needle, deadline, state=None, occur=1):
    """持续读取直到 needle 出现 occur 次, 返回 (found, 累计输出)

    配合 _echo_off(): 关闭终端回显后, 读到的内容只含命令的真实输出,
    不会出现命令行回显, 因此 occur=1 即可精确匹配。
    """
    buf = b""
    while time.time() < deadline:
        kind, data = ws_read_once(s, 1.5)
        if kind == "out":
            buf += data
            if buf.count(needle) >= occur:
                return True, buf
        elif kind == "closed":
            return False, buf
    return False, buf


def _echo_off(s):
    """关闭终端回显, 使读到的内容不含命令行本身

    这是文件传输可靠性的关键: 否则我们发送的命令 (含标记文本) 会被
    原样回显, 与命令的真实输出混在一起, 无法区分。
    """
    ws_send_input(s, b"stty -echo 2>/dev/null; echo __ECHO_OFF__\n")
    _read_until(s, b"__ECHO_OFF__", time.time() + 15, occur=2)


def _echo_on(s):
    """恢复终端回显 (会话结束前调用, 避免影响后续交互)"""
    try:
        ws_send_input(s, b"stty echo 2>/dev/null\n")
    except Exception:
        pass


def run_upload(prof, local_path, remote_path, opts):
    """上传本地文件到远端; 返回 0 成功, 非 0 失败"""
    if not os.path.isfile(local_path):
        eprint(f"本地文件不存在: {local_path}")
        return 2
    size = os.path.getsize(local_path)
    remote_path = remote_path or os.path.basename(local_path)

    # 体积护栏: 终端通道不适合大文件, 提前拒绝比传一半失败更友好
    if size > SMALL_FILE_LIMIT and not opts.get("force"):
        eprint(f"文件 {size / 1048576:.1f}MB 超过终端通道建议上限 "
               f"({SMALL_FILE_LIMIT // 1048576}MB)。")
        eprint("终端通道只适合配置/日志/脚本等中小文件。大文件请用:")
        eprint("  croc send <文件>            # 两端各装 croc, P2P 优先, 无需域名")
        eprint("  或 rsync / scp 到自己的 VPS")
        eprint("如确需尝试, 加 --force (可能中途超时)。")
        return 2

    # 远端目标目录
    remote_dir = os.path.dirname(remote_path)
    remote_name = os.path.basename(remote_path)
    if not remote_name:
        eprint(f"远端路径无效: {remote_path}")
        return 2
    # 分块/批量: 往返延迟是主要成本 (实测 CF 隧道 ~0.5s/次)。
    # 默认 8KB x 4 = 32KB/批, 是在真实链路上验证过的稳定值。
    chunk_size = int(opts.get("chunk") or 8192)
    batch = max(1, min(64, int(opts.get("batch") or 4)))

    token = curl_token(prof, opts)
    s = ws_session(prof, token, (240, 60), opts)
    try:
        wait_first_output(s, 6.0, quiet=True)
        # 关闭回显: 之后读到的都是命令真实输出, 标记匹配无歧义
        _echo_off(s)
        # 准备远端目录并清空目标文件
        prep = "mkdir -p %s && : > %s && echo %s" % (
            _shq(remote_dir or "."), _shq(remote_path), _UP_BEGIN)
        ws_send_input(s, (prep + "\n").encode())
        ok, _ = _read_until(s, _UP_BEGIN.encode(), time.time() + 30)
        if not ok:
            eprint("远端准备失败 (无法创建目标文件)")
            return 1

        sent = 0
        t0 = time.time()
        # 批量提交: 每个 WebSocket 帧里塞 batch 块, 只等一次确认。
        # 逐块等待确认会把往返延迟放大到每块一次, 吞吐被压到几十 KB/s。
        pending = []          # 待发送的 base64 块
        batch_no = 0
        last_idx = 0

        def flush_batch():
            nonlocal pending, batch_no, last_idx, sent
            if not pending:
                return True
            batch_no += 1
            # 一次写入所有块, 最后打印批次标记
            parts = []
            for b64 in pending:
                parts.append("printf '%%s' %s | base64 -d >> %s" % (_shq(b64), _shq(remote_path)))
            parts.append("echo %s_%d" % (_UP_CHUNK_OK, batch_no))
            ws_send_input(s, ("; ".join(parts) + "\n").encode())
            want = ("%s_%d" % (_UP_CHUNK_OK, batch_no)).encode()
            # 超时按数据量估算: 基础 30s + 每 MB 约 10s, 给慢链路留足余量
            budget = 30 + int(sent / 1048576) * 10
            ok, _ = _read_until(s, want, time.time() + budget)
            if not ok:
                return False
            pending = []
            return True

        with open(local_path, "rb") as f:
            idx = 0
            while True:
                block = f.read(chunk_size)
                if not block:
                    break
                idx += 1
                pending.append(base64.b64encode(block).decode("ascii"))
                sent += len(block)
                last_idx = idx
                if len(pending) >= batch:
                    if not flush_batch():
                        eprint(f"第 {batch_no} 批传输失败 (远端未确认)")
                        return 1
                    if not opts.get("json"):
                        pct = (sent * 100 // size) if size else 100
                        sys.stderr.write("\r  上传中 %3d%% (%d/%d 字节)" % (pct, sent, size))
                        sys.stderr.flush()
            if not flush_batch():
                eprint(f"第 {batch_no} 批传输失败 (远端未确认)")
                return 1
        if not opts.get("json"):
            sys.stderr.write("\n")

        # 远端校验大小
        verify = "wc -c < %s" % _shq(remote_path)
        ws_send_input(s, ("echo %s; %s; echo %s\n" % (_UP_DONE, verify, _UP_DONE)).encode())
        ok, out = _read_until(s, _UP_DONE.encode(), time.time() + 40)
        if not ok:
            eprint("远端校验失败")
            return 1
        remote_size = None
        for line in out.decode("utf-8", "replace").splitlines():
            line = line.strip()
            if line.isdigit():
                remote_size = int(line)
        if remote_size is not None and remote_size != size:
            eprint(f"大小不一致: 本地 {size} 字节, 远端 {remote_size} 字节")
            return 1

        elapsed = time.time() - t0
        if opts.get("json"):
            print(json.dumps({"ok": True, "action": "upload", "local": local_path,
                              "remote": remote_path, "bytes": sent,
                              "seconds": round(elapsed, 2)}, ensure_ascii=False))
        else:
            print(f"✅ 上传完成: {local_path} → {remote_path} ({sent} 字节, {elapsed:.1f}s)")
        return 0
    finally:
        _echo_on(s)
        try:
            s.close()
        except Exception:
            pass


def run_download(prof, remote_path, local_path, opts):
    """从远端下载文件; 返回 0 成功, 非 0 失败"""
    chunk_size = int(opts.get("chunk") or 8192)
    local_path = local_path or os.path.basename(remote_path.rstrip("/"))
    if not local_path:
        eprint("无法确定本地文件名, 请显式指定")
        return 2

    token = curl_token(prof, opts)
    s = ws_session(prof, token, (240, 60), opts)
    try:
        wait_first_output(s, 6.0, quiet=True)
        _echo_off(s)
        # 先确认远端文件存在并取大小
        probe = ("echo %s; if [ -f %s ]; then wc -c < %s; else echo %s; fi; echo %s" % (
            _DL_BEGIN, _shq(remote_path), _shq(remote_path), _DL_ERR, _DL_END))
        ws_send_input(s, (probe + "\n").encode())
        ok, out = _read_until(s, _DL_END.encode(), time.time() + 40)
        if not ok:
            eprint(f"远端文件不可读: {remote_path}")
            return 1
        text = out.decode("utf-8", "replace")
        if _DL_ERR in text:
            eprint(f"远端文件不可读: {remote_path}")
            return 1
        total = None
        # 取最后一个纯数字行 (跳过命令回显与标记行)
        for line in text.splitlines():
            line = line.strip()
            if line.isdigit():
                total = int(line)
        if total is None:
            eprint(f"远端文件不可读: {remote_path}")
            return 1

        # 体积护栏: 下载同样受终端通道吞吐限制, 提前拒绝比卡几小时好
        if total > SMALL_FILE_LIMIT and not opts.get("force"):
            eprint(f"远端文件 {total / 1048576:.1f}MB 超过终端通道建议上限 "
                   f"({SMALL_FILE_LIMIT // 1048576}MB)。")
            eprint("终端通道实测约 11KB/s, 大文件请用 croc 或 rsync。")
            eprint("如确需尝试, 加 --force (可能中途超时)。")
            return 2

        tmp_path = local_path + ".part"
        received = 0
        t0 = time.time()
        # 分块读取: tail -c +N 从第 N 字节起取, head -c M 截断到 M 字节
        # (比 dd bs=1 快一个数量级; 两者都是 coreutils/busybox 通用命令)
        # 结束标记用 "标记_偏移" 形式, 且命令回显里也含该串, 因此要等到
        # 第二个出现位置之后才算真正完成 (见 _extract_b64 的切分逻辑)。
        offset = 0
        with open(tmp_path, "wb") as f:
            while offset < total:
                cmd = ("tail -c +%d %s | head -c %d | base64 | tr -d '\\n'; "
                       "echo; echo %s_%d") % (
                    offset + 1, _shq(remote_path), chunk_size, _DL_END, offset)
                ws_send_input(s, (cmd + "\n").encode())
                want = ("%s_%d" % (_DL_END, offset)).encode()
                ok, out = _read_until(s, want, time.time() + 120)
                if not ok:
                    eprint(f"偏移 {offset} 处读取超时")
                    f.close()
                    _safe_unlink(tmp_path)
                    return 1
                # 从输出里取出 base64 段 (最后两行是空行与结束标记)
                b64 = _extract_b64(out, want)
                if b64 is None:
                    eprint(f"偏移 {offset} 处数据解析失败")
                    f.close()
                    _safe_unlink(tmp_path)
                    return 1
                try:
                    block = base64.b64decode(b64)
                except Exception:
                    eprint(f"偏移 {offset} 处 base64 解码失败")
                    f.close()
                    _safe_unlink(tmp_path)
                    return 1
                if not block:
                    break
                f.write(block)
                offset += len(block)
                received += len(block)
                if not opts.get("json"):
                    pct = (received * 100 // total) if total else 100
                    sys.stderr.write("\r  下载中 %3d%% (%d/%d 字节)" % (pct, received, total))
                    sys.stderr.flush()
        if not opts.get("json"):
            sys.stderr.write("\n")

        if received != total:
            eprint(f"大小不一致: 期望 {total} 字节, 实际 {received} 字节")
            _safe_unlink(tmp_path)
            return 1
        os.replace(tmp_path, local_path)
        elapsed = time.time() - t0
        if opts.get("json"):
            print(json.dumps({"ok": True, "action": "download", "remote": remote_path,
                              "local": local_path, "bytes": received,
                              "seconds": round(elapsed, 2)}, ensure_ascii=False))
        else:
            print(f"✅ 下载完成: {remote_path} → {local_path} ({received} 字节, {elapsed:.1f}s)")
        return 0
    finally:
        _echo_on(s)
        try:
            s.close()
        except Exception:
            pass


def _extract_b64(raw, end_marker):
    """从终端输出里剥离出纯 base64 数据

    关闭回显后, 输出形如:
        bash-3.2$ <base64 数据>\r\nCRT_DL_END_<offset>\r\n
    提示符与数据粘在同一行, 因此不能整行匹配, 需要把行内的 base64
    片段单独抠出来 (去掉提示符等非 base64 前缀)。
    """
    text = raw.decode("utf-8", "replace")
    # 去掉结束标记及其后内容
    cut = text.find(end_marker.decode("ascii"))
    if cut >= 0:
        text = text[:cut]
    pieces = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        # 在行内查找最长的纯 base64 片段 (允许 = 结尾)
        best = ""
        for m in re.finditer(r"[A-Za-z0-9+/]{16,}={0,2}", line):
            if len(m.group(0)) > len(best):
                best = m.group(0)
        if best:
            pieces.append(best)
    if not pieces:
        return None
    return "".join(pieces)


def _shq(value):
    """单引号安全转义, 用于拼进远端 shell 命令"""
    return "'" + str(value).replace("'", "'\\''") + "'"


def _safe_unlink(path):
    try:
        os.unlink(path)
    except OSError:
        pass


# ---------------------------------------------------------------
# 连通性自检 (--check)
# ---------------------------------------------------------------
def run_check(prof, opts):
    t0 = time.time()
    try:
        token = curl_token(prof, opts)
    except SystemExit as e:
        return _check_fail(prof, opts, f"token 获取失败: {e}", t0)
    t1 = time.time()
    try:
        s = ws_session(prof, token, (100, 30), opts)
    except SystemExit as e:
        return _check_fail(prof, opts, f"会话建立失败: {e}", t1)

    marker = "CRT_CHECK_%d" % int(t1)
    echo_state = "unconfirmed"
    try:
        ws_send_input(s, ("echo %s\n" % marker).encode())
        buf = b""
        end = time.time() + 8
        while time.time() < end:
            kind, data = ws_read_once(s, 1.5)
            if kind == "out":
                buf += data
                if marker.encode() in buf:
                    echo_state = "ok"
                    break
            elif kind == "closed":
                break
        s.close()
    except Exception:
        pass
    t2 = time.time()

    if opts.get("json"):
        print(json.dumps({
            "ok": True,
            "host": prof["host"],
            "token_seconds": round(t1 - t0, 2),
            "handshake_seconds": round(t2 - t1, 2),
            "echo": echo_state,
            "total_seconds": round(t2 - t0, 2),
        }, ensure_ascii=False))
    else:
        print(f"✅ 连接正常: {prof['host']} | token {t1 - t0:.2f}s | 握手 {t2 - t1:.2f}s | 总计 {t2 - t0:.2f}s")
        if echo_state != "ok":
            print("   (注: 回显未确认, 但会话已建立)")
    return 0


def _check_fail(prof, opts, msg, t0):
    if opts.get("json"):
        print(json.dumps({"ok": False, "host": prof.get("host"), "error": msg}, ensure_ascii=False))
    else:
        eprint(f"❌ 连接失败: {prof.get('host')} | {msg}")
    return 1


# ---------------------------------------------------------------
# 交互式终端
# ---------------------------------------------------------------
def run_interactive(prof, opts):
    token = curl_token(prof, opts)
    try:
        cols, rows = os.get_terminal_size()
    except OSError:
        cols, rows = 120, 40
    s = ws_session(prof, token, (cols, rows), opts)
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
    dbg = debug_enabled()
    dbglog = open("/tmp/crt_debug.log", "ab") if dbg else None

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
                    if dbg:
                        eprint("\r\n[debug] socket closed by remote")
                    eprint("\r\n[连接已断开]")
                    break
            if 0 in rl:
                data = os.read(0, 4096)
                dlog(f"stdin={data!r}")
                if dbg:
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
    return 0


# ---------------------------------------------------------------
# 配置管理: --list / --add-server
# ---------------------------------------------------------------
def list_servers(opts):
    path = config_path(opts)
    if not os.path.exists(path):
        print(f"(配置文件不存在: {path})")
        return 0
    try:
        with open(path) as f:
            cfg = json.load(f)
    except Exception:
        eprint(f"⚠️  配置文件无法解析: {path}")
        return 1
    servers = cfg.get("servers") or {}
    default = cfg.get("default")
    if not servers:
        print("(无已登记服务器)")
        return 0
    print(f"配置文件: {path}")
    for n in sorted(servers):
        mark = " *" if n == default else "  "
        print(f"{mark} {n}  {servers[n].get('url', '')}")
    return 0


def add_server_cmd(name, opts):
    url = opts.get("url") or os.environ.get("TUNNEL_URL")
    user = opts.get("user") or os.environ.get("TUNNEL_USER")
    password = opts.get("password") or os.environ.get("TUNNEL_PASSWORD")
    if not (url and user and password):
        eprint("需要提供 URL / 用户名 / 密码:")
        eprint("  TUNNEL_URL=... TUNNEL_USER=... TUNNEL_PASSWORD=... connect.sh --add-server 名称")
        eprint("  或 --url / --user / --password 显式传参")
        return 2
    path = config_path(opts)
    cfg = {}
    if os.path.exists(path):
        try:
            with open(path) as f:
                cfg = json.load(f)
        except Exception:
            backup = path + ".bak"
            try:
                os.replace(path, backup)
                eprint(f"⚠️  原配置无法解析, 已备份到 {backup}")
            except Exception:
                pass
            cfg = {}
    if not isinstance(cfg, dict):
        cfg = {}
    servers = cfg.get("servers")
    if not isinstance(servers, dict):
        servers = {}
        cfg["servers"] = servers
    servers[name] = {"url": url, "user": user, "password": password}
    if opts.get("set_default") or not cfg.get("default"):
        cfg["default"] = name
    try:
        with open(path, "w") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)
            f.write("\n")
        os.chmod(path, 0o600)
    except Exception as e:
        eprint(f"写入配置失败: {e}")
        return 2
    print(f"✅ 已登记服务器 '{name}' → {path}")
    if cfg.get("default") == name:
        print("   (已设为默认服务器)")
    return 0


def _collect_positionals(argv, flag):
    """收集 flag 之后的非选项位置参数 (用于 --upload/--download 的目标路径)
    跳过 flag 自身与其取值, 以及所有已知选项与其取值。
    """
    takes_value = {"--proxy", "--timeout", "--config", "--server", "--add-server",
                   "--url", "--user", "--password", "--upload", "--download", "--chunk"}
    out = []
    i = 0
    seen_flag = False
    while i < len(argv):
        a = argv[i]
        if a in takes_value:
            if a == flag:
                seen_flag = True
            i += 2
            continue
        if a.startswith("-"):
            i += 1
            continue
        if seen_flag:
            out.append(a)
        i += 1
    return out


def _target_after(argv, flag):
    """取 flag 之后第一个位置参数 (即传输目标路径), 没有则返回 None"""
    vals = _collect_positionals(argv, flag)
    return vals[0] if vals else None


def main():
    opts, rest = parse_args()
    if opts.get("help"):
        print(USAGE)
        return 0
    if opts.get("list"):
        return list_servers(opts)
    if opts.get("add_server"):
        return add_server_cmd(opts["add_server"], opts)

    argv = sys.argv[1:]
    try:
        prof, command = build_profile(opts, rest)
        if opts.get("check"):
            return run_check(prof, opts)
        if opts.get("upload"):
            return run_upload(prof, opts["upload"], _target_after(argv, "--upload"), opts)
        if opts.get("download"):
            return run_download(prof, opts["download"], _target_after(argv, "--download"), opts)
        if command:
            return run_exec(prof, command, opts)
        return run_interactive(prof, opts)
    except SystemExit as e:
        if opts.get("json") and e.code not in (0, None):
            msg = e.code if isinstance(e.code, str) else f"exit {e.code}"
            print(json.dumps({"ok": False, "error": msg}, ensure_ascii=False))
        raise
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
