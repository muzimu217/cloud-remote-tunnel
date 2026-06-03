#!/bin/bash
# === OpenClaw 内网穿透一键启动脚本（持久化版）===
# 支持：进程守护 + 开机自启 + 自动重启

WORK_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_ROOT="$(dirname "$WORK_DIR")"
PID_DIR="$HOME/.local/run"
LOG_DIR="$HOME/.local/log"

echo "=== OpenClaw 内网穿透部署（持久化版）==="
echo "工作目录: $WORK_DIR"

# 创建必要目录
mkdir -p ~/.cloudflared ~/.local/bin $PID_DIR $LOG_DIR

# ============================================================
# 第一步：前置依赖检查
# ============================================================
echo ""
echo "[1/7] 检查前置依赖..."

if ! command -v wget &>/dev/null && ! command -v curl &>/dev/null; then
    echo "❌ 缺少下载工具 (wget 或 curl)"
    echo "请安装: apt update && apt install -y wget curl procps"
    exit 1
fi

# 检查进程管理命令
KILL_CMD=""
if command -v pkill &>/dev/null; then
    KILL_CMD="pkill"
elif command -v killall &>/dev/null; then
    KILL_CMD="killall"
fi

echo "✅ 依赖检查通过"

# ============================================================
# 第二步：下载二进制文件（国内镜像）
# ============================================================
echo ""
echo "[2/7] 下载二进制文件..."

TTYD_VERSION="1.7.7"
CF_VERSION="2026.5.2"
GH_MIRROR="https://gh-proxy.com"

download_file() {
    local target="$1"
    local url="$2"
    if command -v wget &>/dev/null; then
        wget -q --timeout=30 -O "$target" "$url" && return 0
    fi
    if command -v curl &>/dev/null; then
        curl -kfsSL --max-time 30 -o "$target" "$url" && return 0
    fi
    return 1
}

# 下载 ttyd
if [ ! -x ~/.local/bin/ttyd ]; then
    echo "下载 ttyd..."
    for ttyd_file in "ttyd.x86_64" "ttyd_linux.x86_64"; do
        if download_file ~/.local/bin/ttyd "${GH_MIRROR}/https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/${ttyd_file}"; then
            if [ -s ~/.local/bin/ttyd ]; then
                chmod +x ~/.local/bin/ttyd
                echo "✅ ttyd 下载成功"
                break
            fi
        fi
    done
fi

# 下载 cloudflared
if [ ! -x ~/.local/bin/cloudflared ]; then
    echo "下载 cloudflared..."
    if download_file ~/.local/bin/cloudflared "${GH_MIRROR}/https://github.com/cloudflare/cloudflared/releases/download/${CF_VERSION}/cloudflared-linux-amd64"; then
        if [ -s ~/.local/bin/cloudflared ]; then
            chmod +x ~/.local/bin/cloudflared
            echo "✅ cloudflared 下载成功"
        fi
    fi
fi

# ============================================================
# 第三步：停止已有进程
# ============================================================
echo ""
echo "[3/7] 停止已有进程..."

stop_process() {
    local proc_name="$1"
    if [ "$KILL_CMD" = "pkill" ]; then
        pkill -x "$proc_name" 2>/dev/null || true
    elif [ "$KILL_CMD" = "killall" ]; then
        killall "$proc_name" 2>/dev/null || true
    else
        ps aux | grep "$proc_name" | grep -v grep | awk '{print $2}' | xargs kill 2>/dev/null || true
    fi
}

# 先停止守护脚本
stop_process tunnel-daemon
stop_process ttyd
stop_process cloudflared
sleep 1
echo "✅ 已清理旧进程"

# ============================================================
# 第四步：配置 Cloudflare Tunnel
# ============================================================
echo ""
echo "[4/7] 配置 Tunnel..."

if [ -f "$WORK_DIR/cloudflared-config.yml" ]; then
    cp "$WORK_DIR/cloudflared-config.yml" ~/.cloudflared/config.yml
    # 修正路径
    sed -i "s|/home/node/.cloudflared/openclaw-tunnel.json|$HOME/.cloudflared/tunnel-credentials.json|g" ~/.cloudflared/config.yml 2>/dev/null || \
    sed "s|/home/node/.cloudflared/openclaw-tunnel.json|$HOME/.cloudflared/tunnel-credentials.json|g" ~/.cloudflared/config.yml > ~/.cloudflared/config.yml.tmp && \
    mv ~/.cloudflared/config.yml.tmp ~/.cloudflared/config.yml
fi

if [ -f "$WORK_DIR/openclaw-tunnel.json" ]; then
    cp "$WORK_DIR/openclaw-tunnel.json" ~/.cloudflared/tunnel-credentials.json
fi

echo "✅ Tunnel 配置完成"

# ============================================================
# 第五步：创建守护脚本
# ============================================================
echo ""
echo "[5/7] 创建进程守护..."

DAEMON_SCRIPT="$HOME/.local/bin/tunnel-daemon.sh"

cat > "$DAEMON_SCRIPT" << 'DAEMON_EOF'
#!/bin/bash
# === 内网穿透进程守护 ===
# 自动检测并重启挂掉的进程

TTYD_BIN="$HOME/.local/bin/ttyd"
CF_BIN="$HOME/.local/bin/cloudflared"
PID_DIR="$HOME/.local/run"
LOG_DIR="$HOME/.local/log"

mkdir -p $PID_DIR $LOG_DIR

start_ttyd() {
    if [ -x "$TTYD_BIN" ] && ! pgrep -x ttyd >/dev/null; then
        nohup "$TTYD_BIN" -p 7681 -W -b /terminal -c openclaw:OpenClaw@2026 bash >> $LOG_DIR/ttyd.log 2>&1 &
        echo $! > $PID_DIR/ttyd.pid
        sleep 1
        echo "[$(date)] ttyd started" >> $LOG_DIR/daemon.log
    fi
}

start_cloudflared() {
    if [ -x "$CF_BIN" ] && ! pgrep -x cloudflared >/dev/null; then
        nohup "$CF_BIN" tunnel --config ~/.cloudflared/config.yml run >> $LOG_DIR/cloudflared.log 2>&1 &
        echo $! > $PID_DIR/cloudflared.pid
        sleep 2
        echo "[$(date)] cloudflared started" >> $LOG_DIR/daemon.log
    fi
}

# 主循环：每 10 秒检查进程状态
while true; do
    start_ttyd
    start_cloudflared
    sleep 10
done
DAEMON_EOF

chmod +x "$DAEMON_SCRIPT"
echo "✅ 守护脚本已创建: $DAEMON_SCRIPT"

# ============================================================
# 第六步：设置开机自启
# ============================================================
echo ""
echo "[6/7] 设置开机自启..."

# 添加 crontab @reboot
CRON_JOB="@reboot $DAEMON_SCRIPT >> $LOG_DIR/cron.log 2>&1"

if command -v crontab &>/dev/null; then
    # 检查是否已存在
    if ! crontab -l 2>/dev/null | grep -q "tunnel-daemon"; then
        (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
        echo "✅ 已添加 crontab @reboot"
    else
        echo "✅ crontab 已存在"
    fi
else
    echo "⚠️  crontab 不可用，无法设置开机自启"
fi

# ============================================================
# 第七步：启动服务
# ============================================================
echo ""
echo "[7/7] 启动服务..."

# 启动守护脚本
nohup "$DAEMON_SCRIPT" >> $LOG_DIR/daemon.log 2>&1 &
echo $! > $PID_DIR/daemon.pid
sleep 3

# 状态检查
echo ""
echo "=== 运行进程 ==="
ps aux | grep -E "ttyd|cloudflared|daemon" | grep -v grep || echo "无进程"

echo ""
echo "=== 访问地址 ==="
echo "Web 终端: https://tunnel.muzimu217.dpdns.org/terminal/"
echo "          用户名: openclaw | 密码: OpenClaw@2026"

echo ""
echo "=== 日志位置 ==="
echo "守护日志: $LOG_DIR/daemon.log"
echo "ttyd 日志: $LOG_DIR/ttyd.log"
echo "Tunnel日志: $LOG_DIR/cloudflared.log"

echo ""
if pgrep -x ttyd >/dev/null && pgrep -x cloudflared >/dev/null; then
    echo "✅ 部署成功！进程守护已启用"
    echo "   - 进程挂掉会自动重启"
    echo "   - 服务器重启后自动启动"
else
    echo "⚠️  启动不完整，查看日志: tail -f $LOG_DIR/daemon.log"
fi