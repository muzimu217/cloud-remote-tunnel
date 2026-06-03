#!/bin/bash
# === OpenClaw 内网穿透一键启动脚本 ===
# 适用于服务器端部署
# 使用方法：将整个目录上传到服务器，执行此脚本

set -e

WORK_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_ROOT="$(dirname "$WORK_DIR")"

echo "=== OpenClaw 内网穿透部署 ==="
echo "工作目录: $WORK_DIR"

# ============================================================
# 第一步：安装依赖
# ============================================================
echo ""
echo "[1/5] 检查依赖..."

# 检测下载工具
if command -v wget &>/dev/null; then
    DL="wget -q --timeout=60 -O"
elif command -v curl &>/dev/null; then
    DL="curl -kfsSL --max-time 60 -o"
else
    echo "❌ 需要 wget 或 curl，请先安装"
    exit 1
fi

# 创建目录
mkdir -p ~/.cloudflared ~/.local/bin

# ============================================================
# 第二步：下载二进制文件
# ============================================================
echo ""
echo "[2/5] 下载必要的二进制文件..."

TTYD_VERSION="1.7.7"
CF_VERSION="2026.5.2"

# 下载 ttyd
if [ ! -x ~/.local/bin/ttyd ]; then
    echo "下载 ttyd..."
    $DL ~/.local/bin/ttyd "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64" || \
    $DL ~/.local/bin/ttyd "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd_linux.x86_64"
    chmod +x ~/.local/bin/ttyd
fi

# 下载 cloudflared
if [ ! -x ~/.local/bin/cloudflared ]; then
    echo "下载 cloudflared..."
    $DL ~/.local/bin/cloudflared "https://github.com/cloudflare/cloudflared/releases/download/${CF_VERSION}/cloudflared-linux-amd64"
    chmod +x ~/.local/bin/cloudflared
fi

echo "✅ 二进制文件准备完成"

# ============================================================
# 第三步：配置 Cloudflare Tunnel
# ============================================================
echo ""
echo "[3/5] 配置 Cloudflare Tunnel..."

# 使用本地的配置文件
cp "$WORK_DIR/cloudflared-config.yml" ~/.cloudflared/config.yml
cp "$WORK_DIR/openclaw-tunnel.json" ~/.cloudflared/tunnel-credentials.json

# 如果配置文件路径需要调整
sed -i "s|/home/node/.cloudflared/openclaw-tunnel.json|~/.cloudflared/tunnel-credentials.json|g" ~/.cloudflared/config.yml 2>/dev/null || \
sed -i '' "s|/home/node/.cloudflared/openclaw-tunnel.json|$HOME/.cloudflared/tunnel-credentials.json|g" ~/.cloudflared/config.yml

echo "✅ Tunnel 配置完成"

# ============================================================
# 第四步：启动 OpenClaw 服务
# ============================================================
echo ""
echo "[4/5] 启动服务..."

# 先停止已有进程
killall ttyd 2>/dev/null || true
killall cloudflared 2>/dev/null || true
sleep 1

# 启动 ttyd Web 终端
if [ -x ~/.local/bin/ttyd ]; then
    ~/.local/bin/ttyd -p 7681 -W -b /terminal -c openclaw:OpenClaw@2026 bash &
    sleep 2
    echo "✅ ttyd Web 终端已启动 (端口 7681)"
fi

# 启动 OpenClaw Gateway（如果存在）
if command -v openclaw &>/dev/null; then
    cd "$BACKUP_ROOT"
    openclaw gateway run &
    sleep 2
    echo "✅ OpenClaw Gateway 已启动"
fi

# 启动 Cloudflare Tunnel
if [ -x ~/.local/bin/cloudflared ]; then
    nohup ~/.local/bin/cloudflared tunnel --config ~/.cloudflared/config.yml run > ~/.cloudflared/tunnel.log 2>&1 &
    sleep 3
    echo "✅ Cloudflare Tunnel 已启动"
fi

# ============================================================
# 第五步：状态检查
# ============================================================
echo ""
echo "[5/5] 服务状态..."
echo ""
echo "=== 运行进程 ==="
ps aux | grep -E "ttyd|cloudflared|openclaw" | grep -v grep

echo ""
echo "=== 访问地址 ==="
echo "Web 终端: https://tunnel.muzimu217.dpdns.org/terminal/"
echo "Web 界面: https://tunnel.muzimu217.dpdns.org/"
echo "SSH 隧道: ssh.muzimu217.dpdns.org"

echo ""
echo "=== 日志文件 ==="
echo "Tunnel 日志: ~/.cloudflared/tunnel.log"
echo ""
echo "✅ 部署完成！"