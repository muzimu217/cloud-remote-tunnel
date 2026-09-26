#!/bin/bash
# === OpenClaw 隧道守护进程 ===
# 每 10 秒检查 ttyd / cloudflared，挂掉自动重启
# 由 server-start-robust.sh 第六步自动拉起，也可手动运行: bash tunnel-daemon.sh

set -u

WORK_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$HOME/.local/log"
PID_DIR="$HOME/.local/run"
mkdir -p "$LOG_DIR" "$PID_DIR"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG_DIR/tunnel-daemon.log"; }

start_ttyd() {
    [ -x "$HOME/.local/bin/ttyd" ] || { log "ttyd 未安装，跳过重启"; return 0; }
    nohup "$HOME/.local/bin/ttyd" -p 7681 -W -b /terminal -c openclaw:OpenClaw@2026 bash \
        >> "$LOG_DIR/ttyd.log" 2>&1 &
    echo $! > "$PID_DIR/ttyd.pid"
    log "ttyd 已重启 (PID $!)"
}

start_cloudflared() {
    [ -x "$HOME/.local/bin/cloudflared" ] || { log "cloudflared 未安装，跳过重启"; return 0; }
    nohup "$HOME/.local/bin/cloudflared" tunnel --config "$HOME/.cloudflared/config.yml" run \
        >> "$LOG_DIR/cloudflared.log" 2>&1 &
    echo $! > "$PID_DIR/cloudflared.pid"
    log "cloudflared 已重启 (PID $!)"
}

log "守护进程启动 (PID $$)"

while true; do
    pgrep -x ttyd >/dev/null 2>&1 || start_ttyd
    pgrep -x cloudflared >/dev/null 2>&1 || start_cloudflared
    sleep 10
done
