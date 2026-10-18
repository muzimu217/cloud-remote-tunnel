#!/bin/bash
# ============================================================
# Cloud Remote Tunnel — 自启动管理 (容器/服务器通用)
# ============================================================
# 受限容器通常没有 systemd, 无法注册系统服务。本脚本用三层策略,
# 自动选择当前环境可用的方式, 让隧道在"重启后"自动恢复:
#
#   ① crontab @reboot   — 有 cron 且可写时优先 (真开机自启)
#   ② shell 登录钩子    — 写入 ~/.profile / ~/.bashrc (幂等标记块);
#                          任何一次终端登录即自动恢复 (容器最常用)
#   ③ 平台启动命令提示  — 平台支持"启动命令/开机脚本"时, 填一行即可
#
# 用法:
#   bash autostart.sh status          查看当前状态与已生效策略
#   bash autostart.sh enable          启用 (自动选择可用策略)
#   bash autostart.sh disable         关闭 (移除钩子与 crontab 条目)
#   bash autostart.sh print-cmd       输出可直接粘贴的"启动命令"
#
# 说明: 全部动作只写用户目录, 不改系统文件; 卸载脚本会一并清理。
# ============================================================
set -u

WORK_DIR="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="${HOME:-/root}"
STATE_DIR="$HOME_DIR/.cloud-remote-tunnel"
APP_DIR="$STATE_DIR/app"
RESUME="$APP_DIR/resume.sh"

MARK_BEGIN="# >>> cloud-remote-tunnel autostart >>>"
MARK_END="# <<< cloud-remote-tunnel autostart <<<"
HOOK_FILES="$HOME_DIR/.profile $HOME_DIR/.bashrc"
CRON_TAG="cloud-remote-tunnel-autostart"

say()  { printf '%s\n' "$*"; }
ok()   { printf '   ✅ %s\n' "$*"; }
warn() { printf '   ⚠️  %s\n' "$*"; }

# ---------------------------------------------------------------
# 部署自启动所需的稳定性文件: resume.sh + 守护脚本副本
# ---------------------------------------------------------------
ensure_app_files() {
    mkdir -p "$APP_DIR/lib"
    # resume.sh: 优先复制包内的; 包内缺失且目标也不存在时, 内联生成最小实现
    if [ -f "$WORK_DIR/resume.sh" ]; then
        cp -f "$WORK_DIR/resume.sh" "$RESUME"
    elif [ ! -f "$RESUME" ]; then
        cat > "$RESUME" <<'RESUME_EOF'
#!/bin/bash
# Cloud Remote Tunnel — 自动恢复入口 (自动生成的最小实现)
set -u
HOME_DIR="${HOME:-/root}"
STATE_DIR="$HOME_DIR/.cloud-remote-tunnel"
APP_DIR="$STATE_DIR/app"
PID_DIR="$HOME_DIR/.local/run"
LOG_DIR="$HOME_DIR/.local/log"
DAEMON="$APP_DIR/tunnel-daemon.sh"
PIDFILE="$PID_DIR/tunnel-daemon.pid"
[ -f "$DAEMON" ] || exit 0
mkdir -p "$PID_DIR" "$LOG_DIR"
if [ -f "$PIDFILE" ]; then
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && exit 0
fi
if command -v pgrep >/dev/null 2>&1 && pgrep -f "tunnel-daemon\.sh" >/dev/null 2>&1; then
    exit 0
fi
nohup bash "$DAEMON" >> "$LOG_DIR/daemon-output.log" 2>&1 &
echo $! > "$PIDFILE"
exit 0
RESUME_EOF
    fi
    chmod +x "$RESUME" 2>/dev/null || true
    # 守护脚本 + 公共库副本 (容器重启后原解压目录可能已不在)
    [ -f "$WORK_DIR/tunnel-daemon.sh" ] && cp -f "$WORK_DIR/tunnel-daemon.sh" "$APP_DIR/tunnel-daemon.sh"
    [ -f "$WORK_DIR/lib/common.sh" ] && cp -f "$WORK_DIR/lib/common.sh" "$APP_DIR/lib/common.sh"
    # 管理器自身副本 (卸载脚本 app 缺失时也能找到 disable 入口)
    [ -f "$WORK_DIR/autostart.sh" ] && cp -f "$WORK_DIR/autostart.sh" "$APP_DIR/autostart.sh"
    chmod +x "$APP_DIR/tunnel-daemon.sh" "$APP_DIR/autostart.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------
# crontab @reboot (策略①)
# ---------------------------------------------------------------
cron_supported() {
    # 测试开关: CRT_NO_CRON=1 时跳过 crontab 操作 (防止测试污染真实 crontab)
    [ "${CRT_NO_CRON:-}" = "1" ] && return 1
    command -v crontab >/dev/null 2>&1
}

cron_enabled() {
    cron_supported || return 1
    crontab -l 2>/dev/null | grep -q "$CRON_TAG"
}

cron_enable() {
    cron_supported || return 1
    cron_enabled && return 0
    ( crontab -l 2>/dev/null; printf '@reboot /bin/bash %s >/dev/null 2>&1 # %s\n' "$RESUME" "$CRON_TAG" ) | crontab - 2>/dev/null || return 1
    cron_enabled
}

cron_disable() {
    cron_supported || return 0
    cron_enabled || return 0
    crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab - 2>/dev/null || true
}

# ---------------------------------------------------------------
# shell 登录钩子 (策略②)
# ---------------------------------------------------------------
hook_present() {
    local f
    for f in $HOOK_FILES; do
        [ -f "$f" ] || continue
        grep -qF "$MARK_BEGIN" "$f" && return 0
    done
    return 1
}

hook_install_one() {
    local f="$1"
    [ -f "$f" ] || : > "$f" 2>/dev/null || return 0
    grep -qF "$MARK_BEGIN" "$f" && return 0   # 幂等: 已存在则跳过
    {
        printf '\n%s\n' "$MARK_BEGIN"
        printf '# 隧道自动恢复 (由 cloud-remote-tunnel 安装; 删除本块即关闭)\n'
        printf '[ -x "%s" ] && "%s" >/dev/null 2>&1\n' "$RESUME" "$RESUME"
        printf '%s\n' "$MARK_END"
    } >> "$f" 2>/dev/null || return 0
    return 0
}

hook_enable() {
    local f
    for f in $HOOK_FILES; do
        hook_install_one "$f"
    done
    hook_present
}

hook_disable() {
    local f tmp
    for f in $HOOK_FILES; do
        [ -f "$f" ] || continue
        grep -qF "$MARK_BEGIN" "$f" || continue
        tmp="$f.crt.tmp"
        # 删除标记块 (含起止行)
        awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
            $0 == b {skip=1; next}
            $0 == e {skip=0; next}
            !skip {print}
        ' "$f" > "$tmp" 2>/dev/null && mv "$tmp" "$f"
    done
    return 0
}

# ---------------------------------------------------------------
# 平台启动命令 (策略③)
# ---------------------------------------------------------------
print_cmd() {
    say "bash $RESUME"
}

# ---------------------------------------------------------------
# 状态
# ---------------------------------------------------------------
show_status() {
    say "Cloud Remote Tunnel — 自启动状态"
    say "----------------------------------------------"
    if [ -f "$RESUME" ]; then
        ok "恢复入口: $RESUME"
    else
        warn "恢复入口不存在 (先运行 install.sh / server-start-robust.sh)"
    fi
    if [ -f "$APP_DIR/tunnel-daemon.sh" ]; then
        ok "守护脚本副本: $APP_DIR/tunnel-daemon.sh"
    else
        warn "守护脚本副本不存在 (enable 时会自动补齐)"
    fi
    say ""
    if cron_supported; then
        if cron_enabled; then ok "crontab @reboot: 已启用"
        else warn "crontab @reboot: 未启用"; fi
    else
        warn "crontab: 环境不可用 (容器常见, 用登录钩子替代)"
    fi
    if hook_present; then
        ok "shell 登录钩子: 已安装 ($HOOK_FILES)"
    else
        warn "shell 登录钩子: 未安装"
    fi
    say ""
    say "手工启动命令 (平台支持'启动命令'时直接填这一行):"
    say "  $(print_cmd)"
}

# ---------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------
CMD="${1:-status}"

case "$CMD" in
    status)
        show_status
        ;;
    enable)
        say "启用自启动 (自动选择可用策略)..."
        ensure_app_files
        got=""
        if cron_enable; then
            ok "策略① crontab @reboot 已启用"
            got="cron"
        else
            warn "策略① crontab 不可用, 跳过"
        fi
        if hook_enable; then
            ok "策略② shell 登录钩子已安装 (登录即恢复)"
            got="$got hook"
        else
            warn "策略② 登录钩子安装失败"
        fi
        say ""
        if [ -n "$got" ]; then
            say "✅ 自启动已启用: 容器重启后, 任意一次终端登录 (或 cron 触发) 即自动恢复隧道"
        else
            say "⚠️  未能启用任何自动策略, 请在平台侧把下面这行填入'启动命令':"
            say "   $(print_cmd)"
        fi
        ;;
    disable)
        say "关闭自启动..."
        if hook_present; then
            hook_disable && ok "登录钩子已移除"
        else
            say "   (无登录钩子, 跳过)"
        fi
        if cron_enabled; then
            cron_disable && ok "crontab 条目已移除"
        else
            say "   (无 crontab 条目, 跳过)"
        fi
        say "✅ 已关闭 (服务本身不受影响, 仍由守护进程维持)"
        ;;
    print-cmd)
        print_cmd
        ;;
    *)
        say "未知参数: $CMD"
        say "用法: bash autostart.sh [status|enable|disable|print-cmd]"
        exit 2
        ;;
esac
