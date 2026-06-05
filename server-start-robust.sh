#!/bin/bash
# === OpenClaw 内网穿透一键启动脚本（健壮版 v2）===
# 适用于白板服务器 / K8s 容器部署
# 自动检测并处理前置依赖，启动服务 + 守护进程
# 用法：bash server-start-robust.sh

set -euo pipefail

WORK_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_ROOT="$(dirname "$WORK_DIR")"
LOG_DIR="$HOME/.local/log"
PID_DIR="$HOME/.local/run"

echo "=== OpenClaw 内网穿透部署（健壮版 v2）==="
echo "工作目录: $WORK_DIR"
echo ""

# 创建必要目录
mkdir -p "$LOG_DIR" "$PID_DIR" "$HOME/.local/bin" "$HOME/.cloudflared"

# ============================================================
# 第一步：前置依赖检查与安装
# ============================================================
echo "[1/8] 检查前置依赖..."

# 检查下载工具
if ! command -v wget &>/dev/null && ! command -v curl &>/dev/null; then
    echo ""
    echo "❌ 缺少下载工具 (wget 或 curl)"
    echo ""
    echo "请根据系统类型安装："
    echo "  Ubuntu/Debian: apt update && apt install -y wget curl procps"
    echo "  CentOS/RHEL:   yum install -y wget curl procps"
    echo "  Alpine:        apk add wget curl procps"
    echo ""
    exit 1
fi

echo "✅ 依赖检查通过"
echo "   下载工具: $(command -v wget 2>/dev/null || command -v curl 2>/dev/null)"

# ============================================================
# 第二步：下载二进制文件（国内镜像加速）
# ============================================================
echo ""
echo "[2/8] 下载必要的二进制文件..."

TTYD_VERSION="1.7.7"
CF_VERSION="2026.5.2"

# 下载函数（自动尝试 wget/curl）
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

# 国内 GitHub 镜像源
GH_MIRROR="https://gh-proxy.com"

# 下载 ttyd
if [ ! -x "$HOME/.local/bin/ttyd" ]; then
    echo "下载 ttyd v${TTYD_VERSION}..."
    TTYD_SUCCESS=false
    for ttyd_file in "ttyd.x86_64" "ttyd_linux.x86_64"; do
        if [ "$TTYD_SUCCESS" = false ]; then
            if download_file "$HOME/.local/bin/ttyd" "${GH_MIRROR}/https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/${ttyd_file}"; then
                if [ -s "$HOME/.local/bin/ttyd" ]; then
                    chmod +x "$HOME/.local/bin/ttyd"
                    TTYD_SUCCESS=true
                    echo "✅ ttyd 下载成功"
                fi
            fi
        fi
    done

    if [ "$TTYD_SUCCESS" = false ]; then
        echo "❌ ttyd 下载失败，请手动下载放到: $HOME/.local/bin/ttyd"
        echo "   https://github.com/tsl0922/ttyd/releases"
    fi
else
    echo "✅ ttyd 已存在，跳过下载"
fi

# 下载 cloudflared
if [ ! -x "$HOME/.local/bin/cloudflared" ]; then
    echo "下载 cloudflared v${CF_VERSION}..."
    if download_file "$HOME/.local/bin/cloudflared" "${GH_MIRROR}/https://github.com/cloudflare/cloudflared/releases/download/${CF_VERSION}/cloudflared-linux-amd64"; then
        if [ -s "$HOME/.local/bin/cloudflared" ]; then
            chmod +x "$HOME/.local/bin/cloudflared"
            echo "✅ cloudflared 下载成功"
        fi
    else
        echo "❌ cloudflared 下载失败，请手动下载放到: $HOME/.local/bin/cloudflared"
        echo "   https://github.com/cloudflare/cloudflared/releases"
    fi
else
    echo "✅ cloudflared 已存在，跳过下载"
fi

# ============================================================
# 第三步：停止已有进程
# ============================================================
echo ""
echo "[3/8] 停止已有进程..."

# 停止守护进程
if [ -f "$PID_DIR/tunnel-daemon.pid" ]; then
    old_pid=$(cat "$PID_DIR/tunnel-daemon.pid" 2>/dev/null)
    if [ -n "$old_pid" ] && ps -p "$old_pid" >/dev/null 2>&1; then
        kill "$old_pid" 2>/dev/null || true
        echo "   已停止旧守护进程 (PID: $old_pid)"
    fi
fi

# 停止服务进程
pkill -x ttyd 2>/dev/null || true
pkill -x cloudflared 2>/dev/null || true
sleep 1

echo "✅ 已清理旧进程"

# ============================================================
# 第四步：配置 Cloudflare Tunnel
# ============================================================
echo ""
echo "[4/8] 配置 Cloudflare Tunnel..."

# 复制配置文件
if [ -f "$WORK_DIR/cloudflared-config.yml" ]; then
    cp "$WORK_DIR/cloudflared-config.yml" "$HOME/.cloudflared/config.yml"
    echo "   已复制 cloudflared-config.yml"
else
    echo "❌ 缺少 cloudflared-config.yml"
    exit 1
fi

if [ -f "$WORK_DIR/openclaw-tunnel.json" ]; then
    cp "$WORK_DIR/openclaw-tunnel.json" "$HOME/.cloudflared/tunnel-credentials.json"
    echo "   已复制 openclaw-tunnel.json"
else
    echo "❌ 缺少 openclaw-tunnel.json"
    exit 1
fi

# 修正配置文件中的凭证路径
if sed --version 2>/dev/null | grep -q GNU; then
    sed -i "s|/home/node/.cloudflared/openclaw-tunnel.json|$HOME/.cloudflared/tunnel-credentials.json|g" "$HOME/.cloudflared/config.yml"
else
    sed "s|/home/node/.cloudflared/openclaw-tunnel.json|$HOME/.cloudflared/tunnel-credentials.json|g" "$HOME/.cloudflared/config.yml" > "$HOME/.cloudflared/config.yml.tmp"
    mv "$HOME/.cloudflared/config.yml.tmp" "$HOME/.cloudflared/config.yml"
fi

echo "✅ Tunnel 配置完成"

# ============================================================
# 第五步：启动服务（ttyd + cloudflared）
# ============================================================
echo ""
echo "[5/8] 启动服务..."

# 启动 ttyd Web 终端
if [ -x "$HOME/.local/bin/ttyd" ]; then
    nohup "$HOME/.local/bin/ttyd" -p 7681 -W -b /terminal -c openclaw:OpenClaw@2026 bash \
        > "$LOG_DIR/ttyd.log" 2>&1 &
    echo $! > "$PID_DIR/ttyd.pid"
    sleep 2
    if pgrep -x ttyd >/dev/null; then
        echo "✅ ttyd Web 终端已启动 (端口 7681)"
    else
        echo "❌ ttyd 启动失败，查看日志: tail -20 $LOG_DIR/ttyd.log"
    fi
else
    echo "⚠️  ttyd 未安装，跳过"
fi

# 启动 Cloudflare Tunnel
if [ -x "$HOME/.local/bin/cloudflared" ]; then
    nohup "$HOME/.local/bin/cloudflared" tunnel --config "$HOME/.cloudflared/config.yml" run \
        > "$LOG_DIR/cloudflared.log" 2>&1 &
    echo $! > "$PID_DIR/cloudflared.pid"
    sleep 3
    if pgrep -x cloudflared >/dev/null; then
        echo "✅ Cloudflare Tunnel 已启动"
    else
        echo "❌ Tunnel 启动失败，查看日志: tail -20 $LOG_DIR/cloudflared.log"
    fi
else
    echo "⚠️  cloudflared 未安装，跳过"
fi

# ============================================================
# 第六步：启动守护进程（持久化关键）
# ============================================================
echo ""
echo "[6/8] 启动守护进程..."

DAEMON_SCRIPT="$WORK_DIR/tunnel-daemon.sh"
if [ -f "$DAEMON_SCRIPT" ]; then
    nohup bash "$DAEMON_SCRIPT" > "$LOG_DIR/daemon-output.log" 2>&1 &
    DAEMON_PID=$!
    echo $DAEMON_PID > "$PID_DIR/tunnel-daemon.pid"
    sleep 2
    if ps -p "$DAEMON_PID" >/dev/null 2>&1; then
        echo "✅ 守护进程已启动 (PID: $DAEMON_PID)"
        echo "   每 10 秒自动检查服务状态，挂掉自动重启"
    else
        echo "❌ 守护进程启动失败"
    fi
else
    echo "⚠️  tunnel-daemon.sh 不存在，跳过守护进程"
    echo "   服务不会自动恢复，请手动监控"
fi

# ============================================================
# 第七步：获取并输出网关令牌
# ============================================================
echo ""
echo "[7/8] 获取网关令牌..."

GATEWAY_PORT=18789
GATEWAY_TOKEN=""

# 方法1：从环境变量获取
if [ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
    GATEWAY_TOKEN="$OPENCLAW_GATEWAY_TOKEN"
    echo "   从环境变量获取令牌"
fi

# 方法2：从 Gateway API 获取
if [ -z "$GATEWAY_TOKEN" ]; then
    TOKEN_RESPONSE=$(curl -s http://localhost:$GATEWAY_PORT/api/token 2>/dev/null || curl -s http://127.0.0.1:$GATEWAY_PORT/api/token 2>/dev/null)
    if [ -n "$TOKEN_RESPONSE" ] && echo "$TOKEN_RESPONSE" | grep -q "token"; then
        GATEWAY_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -o '"token":"[^"]*"' | cut -d'"' -f4 || echo "$TOKEN_RESPONSE")
        echo "   从 Gateway API 获取令牌"
    fi
fi

# 方法3：从 Gateway 日志获取
if [ -z "$GATEWAY_TOKEN" ]; then
    # 查找可能的 Gateway 日志位置
    for log_path in "$BACKUP_ROOT/logs/gateway.log" "$HOME/.openclaw/logs/gateway.log" "/opt/openclaw/logs/gateway.log"; do
        if [ -f "$log_path" ]; then
            GATEWAY_TOKEN=$(grep -o "token.*[a-zA-Z0-9_-]{20,}" "$log_path" | tail -1 | grep -o "[a-zA-Z0-9_-]{20,}" || "")
            if [ -n "$GATEWAY_TOKEN" ]; then
                echo "   从日志文件获取令牌: $log_path"
                break
            fi
        fi
    done
fi

# 方法4：从 openclaw.json 配置推断（如果配置了固定 token）
if [ -z "$GATEWAY_TOKEN" ]; then
    for config_path in "$BACKUP_ROOT/openclaw.json" "$HOME/.openclaw/openclaw.json"; do
        if [ -f "$config_path" ]; then
            # 检查是否有静态 token 配置
            STATIC_TOKEN=$(grep -o '"token":"[^"]*"' "$config_path" | cut -d'"' -f4 || "")
            if [ -n "$STATIC_TOKEN" ] && [ "$STATIC_TOKEN" != "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
                GATEWAY_TOKEN="$STATIC_TOKEN"
                echo "   从配置文件获取令牌"
                break
            fi
        fi
    done
fi

echo ""
echo "=========================================="
echo "🔑 网关令牌 (Gateway Token)"
echo "=========================================="
if [ -n "$GATEWAY_TOKEN" ]; then
    echo ""
    echo "令牌: $GATEWAY_TOKEN"
    echo ""
    echo "Web 界面访问地址:"
    echo "https://YOUR_DOMAIN/chat?session=agent%3Amain%3Amain&token=$GATEWAY_TOKEN"
    echo ""
    echo "⚠️  请保存此令牌，用于访问 OpenClaw Web 界面"
else
    echo ""
    echo "⚠️  无法自动获取网关令牌"
    echo ""
    echo "请手动执行以下命令获取令牌:"
    echo "  curl http://localhost:$GATEWAY_PORT/api/token"
    echo ""
    echo "或在 Web 终端中启动 OpenClaw Gateway 后查看日志"
fi
echo "=========================================="

# ============================================================
# 第八步：状态检查
# ============================================================
echo ""
echo "[8/8] 服务状态..."
echo ""
echo "=== 运行进程 ==="
ps aux | grep -E "ttyd|cloudflared|tunnel-daemon" | grep -v grep || echo "无相关进程运行"

echo ""
echo "=== 访问地址汇总 ==="
echo ""
echo "📍 Web 终端 (ttyd):"
echo "   https://YOUR_DOMAIN/terminal/"
echo "   用户名: openclaw | 密码: OpenClaw@2026"
echo ""
echo "📍 OpenClaw Web 界面:"
echo "   https://YOUR_DOMAIN/chat?session=agent%3Amain%3Amain"
if [ -n "$GATEWAY_TOKEN" ]; then
    echo "   带令牌: https://YOUR_DOMAIN/chat?session=agent%3Amain%3Amain&token=$GATEWAY_TOKEN"
fi
echo ""
echo "📍 SSH 隧道:"
echo "   ssh.YOUR_DOMAIN"

echo ""
echo "=== 日志文件 ==="
echo "守护日志: $LOG_DIR/tunnel-daemon.log"
echo "ttyd 日志: $LOG_DIR/ttyd.log"
echo "Tunnel 日志: $LOG_DIR/cloudflared.log"
echo "查看实时日志: tail -f $LOG_DIR/tunnel-daemon.log"

echo ""
echo "=== 部署结果 ==="
if pgrep -x cloudflared >/dev/null && pgrep -x ttyd >/dev/null; then
    echo "✅ 部署成功！所有服务运行正常"
    if [ -f "$PID_DIR/tunnel-daemon.pid" ]; then
        daemon_pid=$(cat "$PID_DIR/tunnel-daemon.pid")
        if ps -p "$daemon_pid" >/dev/null 2>&1; then
            echo "✅ 守护进程运行中，服务异常将自动恢复"
        fi
    fi
    if [ -n "$GATEWAY_TOKEN" ]; then
        echo "✅ 网关令牌已获取，请使用上述带令牌的链接访问"
    else
        echo "⚠️  网关令牌未获取，需手动获取后拼接到访问链接"
    fi
else
    echo "⚠️  部署不完整，请检查上述日志和错误信息"
fi

echo ""
echo "=== 后续操作建议 ==="
echo "1. 测试 Web 终端: 浏览器访问 https://YOUR_DOMAIN/terminal/"
echo "2. 测试 Web 界面: 使用上述带令牌的链接访问"
echo "3. 如果令牌获取失败，请在 Web 终端中执行: curl http://localhost:18789/api/token"