#!/bin/bash
# ============================================================
# Cloud Remote Tunnel — 守护进程 (v2)
# ============================================================
# 每 10 秒检查 ttyd / cloudflared, 挂掉自动拉起。
# 凭证与模式读取自 server-start-robust.sh 生成的共享凭证文件
# (~/.cloud-remote-tunnel/credentials.env), 保证重启后密码不变。
#
# 由 server-start-robust.sh 自动拉起; 也可手动运行: bash tunnel-daemon.sh
# ============================================================
set -u

WORK_DIR="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="${HOME:-/root}"
LOG_DIR="$HOME_DIR/.local/log"
PID_DIR="$HOME_DIR/.local/run"
STATE_DIR="$HOME_DIR/.cloud-remote-tunnel"
CRED_FILE="$STATE_DIR/credentials.env"

TTYD_BIN="$HOME_DIR/.local/bin/ttyd"
CF_BIN="$HOME_DIR/.local/bin/cloudflared"

# 公共函数库 (日志截断等)
# shellcheck source=lib/common.sh
[ -f "$WORK_DIR/lib/common.sh" ] && . "$WORK_DIR/lib/common.sh"

mkdir -p "$LOG_DIR" "$PID_DIR"

# 读取共享凭证 (由 server 脚本生成)
TTYD_USER="openclaw"
TTYD_PASS=""
TTYD_PORT="7681"
TUNNEL_MODE="quick"
# shellcheck disable=SC2034  # 由 credentials.env / deploy.conf 覆盖, 保持字段完整
TUNNEL_DOMAIN=""
TUNNEL_TOKEN=""
if [ -f "$CRED_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CRED_FILE"
fi
if [ -f "$WORK_DIR/deploy.conf" ]; then
    # shellcheck source=/dev/null
    . "$WORK_DIR/deploy.conf"
fi

if [ -x /bin/bash ]; then TTYD_SHELL_CHOICE="/bin/bash"; else TTYD_SHELL_CHOICE="/bin/sh"; fi

log() { echo "[$(date '+%F %T')] $*" >> "$LOG_DIR/tunnel-daemon.log"; }

# 日志超限截断: 优先用公共库, 缺失时回退本地实现
if ! command -v crt_trim_log >/dev/null 2>&1; then
    trim_log() {
        local f="$1"
        [ -f "$f" ] || return 0
        local size
        size=$(wc -c < "$f" 2>/dev/null || echo 0)
        if [ "$size" -gt 5242880 ]; then
            if tail -c 1048576 "$f" > "$f.tmp" 2>/dev/null; then
                mv "$f.tmp" "$f"
                log "日志已截断: $(basename "$f") (${size} 字节 → 1MB)"
            fi
        fi
    }
else
    trim_log() {
        local f="$1" before
        [ -f "$f" ] || return 0
        before=$(wc -c < "$f" 2>/dev/null || echo 0)
        crt_trim_log "$f" && [ "$(wc -c < "$f" 2>/dev/null || echo 0)" -lt "$before" ] \
            && log "日志已截断: $(basename "$f") (${before} 字节 → 1MB)"
        return 0
    }
fi

start_ttyd() {
    [ -x "$TTYD_BIN" ] || { log "ttyd 未安装, 跳过重启"; return 0; }
    if [ -z "$TTYD_PASS" ]; then
        log "⚠️ 缺少终端密码 (credentials.env), 无法重启 ttyd — 请重新运行 server-start-robust.sh"
        return 0
    fi
    nohup "$TTYD_BIN" -p "$TTYD_PORT" -i 127.0.0.1 -W -b /terminal -c "${TTYD_USER}:${TTYD_PASS}" "$TTYD_SHELL_CHOICE" \
        >> "$LOG_DIR/ttyd.log" 2>&1 &
    echo $! > "$PID_DIR/ttyd.pid"
    log "ttyd 已重启 (PID $!)"
}

start_cloudflared() {
    [ -x "$CF_BIN" ] || { log "cloudflared 未安装, 跳过重启"; return 0; }
    case "$TUNNEL_MODE" in
        token)
            if [ -z "$TUNNEL_TOKEN" ]; then
                log "⚠️ token 模式但缺少 TUNNEL_TOKEN, 跳过重启"
                return 0
            fi
            nohup "$CF_BIN" tunnel --no-autoupdate run --token "$TUNNEL_TOKEN" \
                >> "$LOG_DIR/cloudflared.log" 2>&1 &
            ;;
        config)
            if [ ! -f "$HOME_DIR/.cloudflared/config.yml" ]; then
                log "⚠️ config 模式但缺少 $HOME_DIR/.cloudflared/config.yml, 跳过重启"
                return 0
            fi
            nohup "$CF_BIN" tunnel --no-autoupdate --config "$HOME_DIR/.cloudflared/config.yml" run \
                >> "$LOG_DIR/cloudflared.log" 2>&1 &
            ;;
        *)
            nohup "$CF_BIN" tunnel --no-autoupdate --url "http://localhost:$TTYD_PORT" \
                >> "$LOG_DIR/cloudflared.log" 2>&1 &
            ;;
    esac
    echo $! > "$PID_DIR/cloudflared.pid"
    log "cloudflared 已重启 (PID $!, 模式 $TUNNEL_MODE)"

    # 临时隧道: 重启后地址会变化, 刷新并记录新地址
    # 写入重启标记, 只匹配标记之后的新 URL, 避免匹配到历史地址
    if [ "$TUNNEL_MODE" = "quick" ]; then
        RESTART_MARK="DAEMON_RESTART_$(date +%s)"
        printf '%s\n' "$RESTART_MARK" >> "$LOG_DIR/cloudflared.log"
        local new_url="" i=0
        while [ $i -lt 30 ]; do
            new_url="$(sed -n "/$RESTART_MARK/,\$p" "$LOG_DIR/cloudflared.log" 2>/dev/null \
                | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -n 1)"
            [ -n "$new_url" ] && break
            sleep 1
            i=$((i + 1))
        done
        if [ -n "$new_url" ]; then
            printf '%s\n' "$new_url" > "$STATE_DIR/quick-url.txt"
            log "临时隧道新地址: $new_url"
        fi
    fi
}

log "守护进程启动 (PID $$, 模式 $TUNNEL_MODE)"

# 完整性巡检: 每 10 分钟检测一次部署文件是否被修改, 只记录警告不自动覆盖
MANIFEST="$STATE_DIR/deployed.sha256"
check_integrity() {
    command -v crt_manifest_verify >/dev/null 2>&1 || return 0
    [ -f "$MANIFEST" ] || return 0
    local issues
    issues="$(crt_manifest_verify "$MANIFEST" 2>/dev/null)" || true
    if [ -n "$issues" ]; then
        log "⚠️ 检测到部署文件被修改: $(printf '%s' "$issues" | tr '\n' ';')"
        log "   如需恢复: 重新运行 install.sh; 如为主动修改请跑 verify.sh --write 更新清单"
    fi
}

while true; do
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -x ttyd >/dev/null 2>&1 || start_ttyd
        pgrep -x cloudflared >/dev/null 2>&1 || start_cloudflared
    fi
    trim_log "$LOG_DIR/ttyd.log"
    trim_log "$LOG_DIR/cloudflared.log"
    trim_log "$LOG_DIR/tunnel-daemon.log"
    # 每 60 个周期 (约 10 分钟) 做一次完整性巡检
    ticks=$(( ${ticks:-0} + 1 ))
    [ $((ticks % 60)) -eq 0 ] && check_integrity
    sleep 10
done
