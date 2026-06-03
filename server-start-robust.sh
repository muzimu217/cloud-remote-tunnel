#!/bin/bash
# === OpenClaw 内网穿透一键启动脚本（无sudo持久化版）===
# 支持：进程守护 + 自我重启 + 无需sudo/crontab

WORK_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$HOME/.local/log"
PID_DIR="$HOME/.local/run"

echo "=== OpenClaw 内网穿透部署（无sudo版）==="
echo "工作目录: $WORK_DIR"

# 创建必要目录
mkdir -p ~/.cloudflared ~/.local/bin $LOG_DIR $PID_DIR

# ============================================================
# 第一步：依赖检查
# ============================================================
echo ""
echo "[1/5] 检查依赖..."

if ! command -v wget &>/dev/null && ! command -v curl &>/dev/null; then
    echo "❌ 缺少下载工具"
    echo "安装: apt update && apt install -y wget curl procps"
    exit 1
fi

if ! command -v pgrep &>/dev/null; then
    echo "❌ 缺少 pgrep"
    echo "安装: apt update && apt install -y procps"
    exit 1
fi

echo "✅ 依赖检查通过"

# ============================================================
# 第二步：下载二进制（国内镜像）
# ============================================================
echo ""
echo "[2/5] 下载二进制..."

GH_MIRROR="https://gh-proxy.com"

download() {
    local target="$1" url="$2"
    wget -q --timeout=30 -O "$target" "$url" 2>/dev/null || \
    curl -kfsSL --max-time 30 -o "$target" "$url" 2>/dev/null
}

# ttyd
if [ ! -x ~/.local/bin/ttyd ]; then
    echo "下载 ttyd..."
    for f in "ttyd.x86_64" "ttyd_linux.x86_64"; do
        if download ~/.local/bin/ttyd "${GH_MIRROR}/https://github.com/tsl0922/ttyd/releases/download/1.7.7/${f}"; then
            [ -s ~/.local/bin/ttyd ] && chmod +x ~/.local/bin/ttyd && echo "✅ ttyd" && break
        fi
    done
fi

# cloudflared
if [ ! -x ~/.local/bin/cloudflared ]; then
    echo "下载 cloudflared..."
    if download ~/.local/bin/cloudflared "${GH_MIRROR}/https://github.com/cloudflare/cloudflared/releases/download/2026.5.2/cloudflared-linux-amd64"; then
        [ -s ~/.local/bin/cloudflared ] && chmod +x ~/.local/bin/cloudflared && echo "✅ cloudflared"
    fi
fi

# ============================================================
# 第三步：配置 Tunnel
# ============================================================
echo ""
echo "[3/5] 配置 Tunnel..."

[ -f "$WORK_DIR/cloudflared-config.yml" ] && cp "$WORK_DIR/cloudflared-config.yml" ~/.cloudflared/config.yml
[ -f "$WORK_DIR/openclaw-tunnel.json" ] && cp "$WORK_DIR/openclaw-tunnel.json" ~/.cloudflared/tunnel-credentials.json

# 修正路径
if [ -f ~/.cloudflared/config.yml ]; then
    sed "s|/home/node/.cloudflared/openclaw-tunnel.json|$HOME/.cloudflared/tunnel-credentials.json|g" ~/.cloudflared/config.yml > ~/.cloudflared/config.tmp
    mv ~/.cloudflared/config.tmp ~/.cloudflared/config.yml
fi

echo "✅ 配置完成"

# ============================================================
# 第四步：停止旧进程，启动守护
# ============================================================
echo ""
echo "[4/5] 启动守护进程..."

# 停止旧进程
pkill -x ttyd 2>/dev/null
pkill -x cloudflared 2>/dev/null
pkill -f "tunnel-watchdog" 2>/dev/null
sleep 1

# 创建 watchdog 脚本（内嵌）
WATCHDOG_SCRIPT=~/.local/bin/tunnel-watchdog.sh
cat > "$WATCHDOG_SCRIPT" << 'EOF'
#!/bin/bash
# 进程守护 - 每10秒检查，挂了自动重启

TTYD="$HOME/.local/bin/ttyd"
CF="$HOME/.local/bin/cloudflared"
LOG="$HOME/.local/log"
PID="$HOME/.local/run"

mkdir -p $LOG $PID

while true; do
    # ttyd 检查
    if [ -x "$TTYD" ] && ! pgrep -x ttyd >/dev/null; then
        nohup "$TTYD" -p 7681 -W -b /terminal -c openclaw:OpenClaw@2026 bash >> $LOG/ttyd.log 2>&1 &
        disown
        echo "[$(date)] ttyd restarted" >> $LOG/watchdog.log
    fi

    # cloudflared 检查
    if [ -x "$CF" ] && ! pgrep -x cloudflared >/dev/null; then
        nohup "$CF" tunnel --config ~/.cloudflared/config.yml run >> $LOG/cloudflared.log 2>&1 &
        disown
        echo "[$(date)] cloudflared restarted" >> $LOG/watchdog.log
    fi

    sleep 10
done
EOF
chmod +x "$WATCHDOG_SCRIPT"

# 启动 watchdog（脱离终端）
nohup "$WATCHDOG_SCRIPT" >> $LOG/watchdog.log 2>&1 &
disown
echo "✅ 守护进程已启动"

# 等待服务启动
sleep 3

# ============================================================
# 第五步：状态验证
# ============================================================
echo ""
echo "[5/5] 验证状态..."

echo ""
echo "=== 进程状态 ==="
pgrep -x ttyd >/dev/null && echo "✅ ttyd 运行中" || echo "❌ ttyd 未运行"
pgrep -x cloudflared >/dev/null && echo "✅ cloudflared 运行中" || echo "❌ cloudflared 未运行"
pgrep -f "tunnel-watchdog" >/dev/null && echo "✅ watchdog 运行中" || echo "❌ watchdog 未运行"

echo ""
echo "=== 访问地址 ==="
echo "Web终端: https://tunnel.muzimu217.dpdns.org/terminal/"
echo "凭证: openclaw / OpenClaw@2026"

echo ""
echo "=== 日志 ==="
echo "tail -f $LOG_DIR/watchdog.log"
echo "tail -f $LOG_DIR/ttyd.log"
echo "tail -f $LOG_DIR/cloudflared.log"

echo ""
echo "=== 持久化说明 ==="
echo "进程守护每10秒检查，挂了自动重启"
echo "watchdog脱离终端运行，会话结束不影响"
echo "重启服务器后需重新执行本脚本"

echo ""
if pgrep -x ttyd >/dev/null && pgrep -x cloudflared >/dev/null; then
    echo "✅ 部署成功！"
else
    echo "⚠️ 启动失败，检查日志"
fi