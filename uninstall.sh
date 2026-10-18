#!/bin/bash
# ============================================================
# Cloud Remote Tunnel — 干净卸载脚本
# ============================================================
# 用法:
#   bash uninstall.sh           停止服务, 删除程序与状态 (保留日志)
#   bash uninstall.sh --purge   连日志与隧道配置文件一并清理
# ============================================================
set -u

PURGE="no"
[ "${1:-}" = "--purge" ] && PURGE="yes"

echo "== 关闭自启动 =="
# 优先用 autostart.sh 清理; 脚本不在时按标记行内联清理
AUTOSTART_SH="$HOME/.cloud-remote-tunnel/app/autostart.sh"
WORK_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ ! -f "$AUTOSTART_SH" ] && [ -f "$WORK_DIR/autostart.sh" ]; then
    AUTOSTART_SH="$WORK_DIR/autostart.sh"
fi
if [ -f "$AUTOSTART_SH" ]; then
    bash "$AUTOSTART_SH" disable >/dev/null 2>&1 && echo "  已关闭自启动 (钩子与 crontab)"
else
    # 内联清理: shell 登录钩子
    for f in "$HOME/.profile" "$HOME/.bashrc"; do
        [ -f "$f" ] || continue
        if grep -qF "# >>> cloud-remote-tunnel autostart >>>" "$f"; then
            awk '
                $0 == "# >>> cloud-remote-tunnel autostart >>>" {skip=1; next}
                $0 == "# <<< cloud-remote-tunnel autostart <<<" {skip=0; next}
                !skip {print}
            ' "$f" > "$f.crt.tmp" && mv "$f.crt.tmp" "$f"
            echo "  已清理登录钩子: $f"
        fi
    done
    # 内联清理: crontab 条目
    if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q "cloud-remote-tunnel-autostart"; then
        crontab -l 2>/dev/null | grep -v "cloud-remote-tunnel-autostart" | crontab - 2>/dev/null || true
        echo "  已清理 crontab 自启动条目"
    fi
fi

echo "== 停止服务 =="
if [ -f "$HOME/.local/run/tunnel-daemon.pid" ]; then
    daemon_pid="$(cat "$HOME/.local/run/tunnel-daemon.pid" 2>/dev/null || true)"
    if [ -n "$daemon_pid" ] && kill "$daemon_pid" 2>/dev/null; then
        echo "  已停止守护进程 (PID $daemon_pid)"
    fi
fi
if command -v pkill >/dev/null 2>&1; then
    pkill -x ttyd 2>/dev/null && echo "  已停止 ttyd" || true
    pkill -x cloudflared 2>/dev/null && echo "  已停止 cloudflared" || true
fi
sleep 1

echo "== 删除程序与状态 =="
# 若曾用 verify.sh --lock 锁定过, 先解锁再删, 否则 chattr +i 的文件删不掉
if command -v chattr >/dev/null 2>&1; then
    for f in "$HOME/.local/bin/ttyd" "$HOME/.local/bin/cloudflared"; do
        [ -f "$f" ] && chattr -i "$f" 2>/dev/null || true
    done
fi
for f in "$HOME/.local/bin/ttyd" "$HOME/.local/bin/cloudflared"; do
    [ -f "$f" ] && chmod u+w "$f" 2>/dev/null || true
done
rm -f "$HOME/.local/bin/ttyd" "$HOME/.local/bin/cloudflared"
rm -rf "$HOME/.cloud-remote-tunnel"
rm -f "$HOME/connection-card.txt"
rm -f "$HOME/.local/run/ttyd.pid" "$HOME/.local/run/cloudflared.pid" "$HOME/.local/run/tunnel-daemon.pid"
echo "  已完成"

if [ "$PURGE" = "yes" ]; then
    echo "== 深度清理 (--purge) =="
    rm -f "$HOME/.local/log/ttyd.log" "$HOME/.local/log/cloudflared.log"
    rm -f "$HOME/.local/log/tunnel-daemon.log" "$HOME/.local/log/daemon-output.log"
    rm -f "$HOME/.cloudflared/config.yml" "$HOME/.cloudflared/tunnel-credentials.json"
    echo "  日志与隧道配置已清理"
fi

echo ""
if command -v pgrep >/dev/null 2>&1; then
    left1="$(pgrep -x ttyd 2>/dev/null | wc -l | tr -d ' ')"
    left2="$(pgrep -x cloudflared 2>/dev/null | wc -l | tr -d ' ')"
    echo "✅ 卸载完成 (残留进程: ttyd=$left1 cloudflared=$left2)"
else
    echo "✅ 卸载完成"
fi
[ "$PURGE" != "yes" ] && echo "  提示: 日志保留在 ~/.local/log/; 如需彻底清理: bash uninstall.sh --purge"
