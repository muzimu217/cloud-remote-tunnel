#!/bin/bash
# ============================================================
# Cloud Remote Tunnel — 自动恢复入口 (静默, 可重复执行)
# ============================================================
# 作用: 确保"守护进程"在运行; 守护进程会进一步拉起 ttyd 与 cloudflared。
#
# 调用方:
#   1) autostart.sh 写入的登录钩子 (打开终端时自动调用);
#   2) 容器平台支持的"启动命令", 直接填:
#        bash $HOME/.cloud-remote-tunnel/app/resume.sh
#   3) 手工排障: bash resume.sh (无输出即已恢复或无需恢复)
#
# 幂等: 守护进程已在运行则立即退出, 不会重复启动。
# ============================================================
set -u

HOME_DIR="${HOME:-/root}"
STATE_DIR="$HOME_DIR/.cloud-remote-tunnel"
APP_DIR="$STATE_DIR/app"
PID_DIR="$HOME_DIR/.local/run"
LOG_DIR="$HOME_DIR/.local/log"
DAEMON="$APP_DIR/tunnel-daemon.sh"
PIDFILE="$PID_DIR/tunnel-daemon.pid"

# 尚未部署过: 无事可做
[ -f "$DAEMON" ] || exit 0

mkdir -p "$PID_DIR" "$LOG_DIR"

# 已在运行? PID 文件优先
if [ -f "$PIDFILE" ]; then
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        exit 0
    fi
fi

# 兜底: 按进程名查 (PID 文件丢失或陈旧时)
# 先按本部署的绝对路径精确匹配; 再退回通用脚本名 (避免漏判导致重复守护)
if command -v pgrep >/dev/null 2>&1; then
    if pgrep -f -- "$DAEMON" >/dev/null 2>&1; then
        exit 0
    fi
    if pgrep -f "tunnel-daemon\.sh" >/dev/null 2>&1; then
        exit 0
    fi
fi

nohup bash "$DAEMON" >> "$LOG_DIR/daemon-output.log" 2>&1 &
echo $! > "$PIDFILE"
exit 0
