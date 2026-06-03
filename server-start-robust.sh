#!/bin/bash
# === OpenClaw 内网穿透一键启动脚本（健壮版）===
# 适用于白板服务器部署
# 自动检测并处理前置依赖问题

WORK_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_ROOT="$(dirname "$WORK_DIR")"

echo "=== OpenClaw 内网穿透部署（健壮版）==="
echo "工作目录: $WORK_DIR"

# ============================================================
# 第一步：前置依赖检查与安装
# ============================================================
echo ""
echo "[1/6] 检查前置依赖..."

MISSING_DEPS=()

# 检查必需命令
for cmd in wget curl; do
    if ! command -v $cmd &>/dev/null; then
        # 至少需要 wget 或 curl 之一
        if [ "$cmd" = "wget" ] && ! command -v curl &>/dev/null; then
            MISSING_DEPS+=("wget 或 curl")
        elif [ "$cmd" = "curl" ] && ! command -v wget &>/dev/null; then
            MISSING_DEPS+=("wget 或 curl")
        fi
    fi
done

# 如果缺少 wget 和 curl，提供安装建议
if ! command -v wget &>/dev/null && ! command -v curl &>/dev/null; then
    echo ""
    echo "❌ 缺少下载工具 (wget 或 curl)"
    echo ""
    echo "请根据系统类型安装："
    echo "  Ubuntu/Debian: apt update && apt install -y wget curl"
    echo "  CentOS/RHEL:   yum install -y wget curl"
    echo "  Alpine:        apk add wget curl"
    echo "  Arch:          pacman -S wget curl"
    echo ""
    exit 1
fi

# 检查 killall 替代方案
KILL_CMD=""
if command -v killall &>/dev/null; then
    KILL_CMD="killall"
elif command -v pkill &>/dev/null; then
    KILL_CMD="pkill"
else
    echo "⚠️  缺少 killall/pkill，将使用 ps+kill 组合"
    KILL_CMD="pskill"  # 自定义函数
fi

echo "✅ 依赖检查通过"
echo "   下载工具: $(command -v wget || command -v curl)"
echo "   进程管理: $KILL_CMD"

# 创建目录
mkdir -p ~/.cloudflared ~/.local/bin

# ============================================================
# 第二步：下载二进制文件（多源备选）
# ============================================================
echo ""
echo "[2/6] 下载必要的二进制文件..."

TTYD_VERSION="1.7.7"
CF_VERSION="2026.5.2"

# 定义下载函数
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

# GitHub 文件名映射
TTYD_FILES=(
    "ttyd.x86_64"
    "ttyd_linux.x86_64"
)

CF_FILE="cloudflared-linux-amd64"

# 下载 ttyd（尝试多个文件名）
if [ ! -x ~/.local/bin/ttyd ]; then
    TTYD_SUCCESS=false
    for ttyd_file in "${TTYD_FILES[@]}"; do
        if [ "$TTYD_SUCCESS" = false ]; then
            echo "尝试下载 ttyd ($ttyd_file)..."
            if download_file ~/.local/bin/ttyd "https://ghproxy.com/github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/${ttyd_file}"; then
                if [ -s ~/.local/bin/ttyd ]; then
                    chmod +x ~/.local/bin/ttyd
                    TTYD_SUCCESS=true
                    echo "✅ ttyd 下载成功"
                fi
            fi
        fi
    done

    if [ "$TTYD_SUCCESS" = false ]; then
        echo "❌ ttyd 下载失败（GitHub 可能不可访问）"
        echo "   请手动下载: https://github.com/tsl0922/ttyd/releases"
        echo "   放到: ~/.local/bin/ttyd"
    fi
fi

# 下载 cloudflared
if [ ! -x ~/.local/bin/cloudflared ]; then
    echo "下载 cloudflared..."
    if download_file ~/.local/bin/cloudflared "https://ghproxy.com/github.com/cloudflare/cloudflared/releases/download/${CF_VERSION}/${CF_FILE}"; then
        if [ -s ~/.local/bin/cloudflared ]; then
            chmod +x ~/.local/bin/cloudflared
            echo "✅ cloudflared 下载成功"
        fi
    else
        echo "❌ cloudflared 下载失败（GitHub 可能不可访问）"
        echo "   请手动下载: https://github.com/cloudflare/cloudflared/releases"
        echo "   放到: ~/.local/bin/cloudflared"
    fi
fi

# 检查是否所有二进制文件都存在
if [ ! -x ~/.local/bin/ttyd ] || [ ! -x ~/.local/bin/cloudflared ]; then
    echo ""
    echo "⚠️  二进制文件不完整，但会尝试继续..."
fi

# ============================================================
# 第三步：停止已有进程
# ============================================================
echo ""
echo "[3/6] 停止已有进程..."

# 使用合适的进程管理命令
stop_process() {
    local proc_name="$1"

    if [ "$KILL_CMD" = "killall" ]; then
        killall "$proc_name" 2>/dev/null || true
    elif [ "$KILL_CMD" = "pkill" ]; then
        pkill -x "$proc_name" 2>/dev/null || true
    else
        # 使用 ps + kill 组合
        local pids=$(ps aux | grep "$proc_name" | grep -v grep | awk '{print $2}')
        for pid in $pids; do
            kill "$pid" 2>/dev/null || true
        done
    fi
}

stop_process ttyd
stop_process cloudflared
sleep 1

echo "✅ 已清理旧进程"

# ============================================================
# 第四步：配置 Cloudflare Tunnel
# ============================================================
echo ""
echo "[4/6] 配置 Cloudflare Tunnel..."

# 使用本地的配置文件
if [ -f "$WORK_DIR/cloudflared-config.yml" ]; then
    cp "$WORK_DIR/cloudflared-config.yml" ~/.cloudflared/config.yml
else
    echo "❌ 缺少 cloudflared-config.yml"
fi

if [ -f "$WORK_DIR/openclaw-tunnel.json" ]; then
    cp "$WORK_DIR/openclaw-tunnel.json" ~/.cloudflared/tunnel-credentials.json
else
    echo "❌ 缺少 openclaw-tunnel.json"
fi

# 调整配置文件路径
if [ -f ~/.cloudflared/config.yml ]; then
    # 使用更兼容的 sed 方式
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i "s|/home/node/.cloudflared/openclaw-tunnel.json|$HOME/.cloudflared/tunnel-credentials.json|g" ~/.cloudflared/config.yml
    else
        # macOS/BSD sed
        sed -i '' "s|/home/node/.cloudflared/openclaw-tunnel.json|$HOME/.cloudflared/tunnel-credentials.json|g" ~/.cloudflared/config.yml 2>/dev/null || \
        # 如果还是失败，创建临时文件
        sed "s|/home/node/.cloudflared/openclaw-tunnel.json|$HOME/.cloudflared/tunnel-credentials.json|g" ~/.cloudflared/config.yml > ~/.cloudflared/config.yml.tmp && \
        mv ~/.cloudflared/config.yml.tmp ~/.cloudflared/config.yml
    fi
fi

echo "✅ Tunnel 配置完成"

# ============================================================
# 第五步：启动服务
# ============================================================
echo ""
echo "[5/6] 启动服务..."

# 启动 ttyd Web 终端
if [ -x ~/.local/bin/ttyd ]; then
    ~/.local/bin/ttyd -p 7681 -W -b /terminal -c openclaw:OpenClaw@2026 bash &
    sleep 2
    if pgrep -x ttyd >/dev/null; then
        echo "✅ ttyd Web 终端已启动 (端口 7681)"
    else
        echo "❌ ttyd 启动失败"
    fi
else
    echo "⚠️  ttyd 未安装，跳过"
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

    if pgrep -x cloudflared >/dev/null; then
        echo "✅ Cloudflare Tunnel 已启动"
    else
        echo "❌ Tunnel 启动失败，查看日志："
        tail -20 ~/.cloudflared/tunnel.log
    fi
else
    echo "⚠️  cloudflared 未安装，跳过"
fi

# ============================================================
# 第六步：状态检查
# ============================================================
echo ""
echo "[6/6] 服务状态..."
echo ""
echo "=== 运行进程 ==="
ps aux | grep -E "ttyd|cloudflared|openclaw" | grep -v grep || echo "无相关进程运行"

echo ""
echo "=== 访问地址 ==="
echo "Web 终端: https://tunnel.muzimu217.dpdns.org/terminal/"
echo "          用户名: openclaw | 密码: OpenClaw@2026"
echo "Web 界面: https://tunnel.muzimu217.dpdns.org/"
echo "SSH 隧道: ssh.muzimu217.dpdns.org"

echo ""
echo "=== 日志文件 ==="
echo "Tunnel 日志: ~/.cloudflared/tunnel.log"
echo "查看日志: tail -f ~/.cloudflared/tunnel.log"

echo ""
echo "=== 验证命令 ==="
echo "本地测试: curl -I https://tunnel.muzimu217.dpdns.org/terminal/"
echo "带认证测试: curl -u 'openclaw:OpenClaw@2026' https://tunnel.muzimu217.dpdns.org/terminal/"

echo ""
if pgrep -x cloudflared >/dev/null && pgrep -x ttyd >/dev/null; then
    echo "✅ 部署成功！所有服务运行正常"
else
    echo "⚠️  部署不完整，请检查上述日志和错误信息"
fi