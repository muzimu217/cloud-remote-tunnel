#!/bin/bash
# ============================================================
# Cloud Remote Tunnel — 服务端一键部署脚本 (v3)
# ============================================================
# 在任意 Linux 云容器 / 云服务器上运行, 自动完成:
#   1) 依赖检查 + 二进制下载 (x86_64 / arm64 / armhf / 386 架构自适应)
#   2) ttyd Web 终端启动 (密码自动生成或环境变量注入, 无任何硬编码凭证)
#   3) cloudflared 隧道启动 (三种模式自动选择: named / token / quick)
#   4) 守护进程启动 (ttyd / cloudflared 挂掉自动拉起)
#   5) 自启动配置 (复制脚本到稳定目录 + crontab @reboot / 登录钩子; AUTOSTART=no 可关)
#   6) 输出"连接卡片": 访问地址 + 账号密码 + 本地免密连接命令 + 自检结果
#
# 用法:   bash server-start-robust.sh
# 配置:   环境变量 或 同目录 deploy.conf (模板见 deploy.conf.example)
#         环境变量优先级最高, 适合 CI / AI 自动化调用
# 文档:   见 README.md
# ============================================================
set -u

WORK_DIR="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="${HOME:-/root}"
LOG_DIR="$HOME_DIR/.local/log"
PID_DIR="$HOME_DIR/.local/run"
STATE_DIR="$HOME_DIR/.cloud-remote-tunnel"
CRED_FILE="$STATE_DIR/credentials.env"
CARD_FILE="$HOME_DIR/connection-card.txt"
QUICK_URL_FILE="$STATE_DIR/quick-url.txt"

TTYD_BIN="$HOME_DIR/.local/bin/ttyd"
CF_BIN="$HOME_DIR/.local/bin/cloudflared"

# 公共函数库 (单一来源: 版本号 / 架构映射 / URL 校验 / 哈希 / 密码生成)
# shellcheck source=lib/common.sh
if [ -f "$WORK_DIR/lib/common.sh" ]; then
    . "$WORK_DIR/lib/common.sh"
else
    echo "❌ 缺少 lib/common.sh (部署包不完整, 请重新获取)" >&2
    exit 1
fi

mkdir -p "$LOG_DIR" "$PID_DIR" "$STATE_DIR" "$HOME_DIR/.local/bin" "$HOME_DIR/.cloudflared"
chmod 700 "$STATE_DIR" 2>/dev/null || true

echo "=== Cloud Remote Tunnel 部署 (v3) ==="
echo "工作目录: $WORK_DIR"
echo ""

# ============================================================
# [1/8] 读取配置 (优先级: 环境变量 > deploy.conf > 上次部署凭证 > 默认值)
# ============================================================
echo "[1/8] 读取配置..."

ENV_TTYD_USER="${TTYD_USER:-}"
ENV_TTYD_PASS="${TTYD_PASS:-}"
ENV_TTYD_PORT="${TTYD_PORT:-}"
ENV_TUNNEL_MODE="${TUNNEL_MODE:-}"
ENV_TUNNEL_DOMAIN="${TUNNEL_DOMAIN:-}"
ENV_TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"
ENV_TTYD_VERSION="${TTYD_VERSION:-}"
ENV_CF_VERSION="${CF_VERSION:-}"
ENV_GH_MIRROR="${GH_MIRROR:-}"
ENV_AUTOSTART="${AUTOSTART:-}"
unset TTYD_USER TTYD_PASS TTYD_PORT TUNNEL_MODE TUNNEL_DOMAIN TUNNEL_TOKEN TTYD_VERSION CF_VERSION GH_MIRROR AUTOSTART

# 第二优先级: 上次部署保存的凭证 (保底历史值)
CREDS_TTYD_USER=""; CREDS_TTYD_PASS=""; CREDS_TTYD_PORT=""
CREDS_TUNNEL_MODE=""; CREDS_TUNNEL_DOMAIN=""; CREDS_TUNNEL_TOKEN=""
if [ -f "$CRED_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CRED_FILE"
    CREDS_TTYD_USER="${TTYD_USER:-}"; CREDS_TTYD_PASS="${TTYD_PASS:-}"
    CREDS_TTYD_PORT="${TTYD_PORT:-}"; CREDS_TUNNEL_MODE="${TUNNEL_MODE:-}"
    CREDS_TUNNEL_DOMAIN="${TUNNEL_DOMAIN:-}"; CREDS_TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"
    unset TTYD_USER TTYD_PASS TTYD_PORT TUNNEL_MODE TUNNEL_DOMAIN TUNNEL_TOKEN
fi

# 第三优先级: deploy.conf (可显式覆盖, 留空视为未设置)
DEPLOY_TTYD_USER=""; DEPLOY_TTYD_PASS=""; DEPLOY_TTYD_PORT=""
DEPLOY_TUNNEL_MODE=""; DEPLOY_TUNNEL_DOMAIN=""; DEPLOY_TUNNEL_TOKEN=""
DEPLOY_TTYD_VERSION=""; DEPLOY_CF_VERSION=""; DEPLOY_GH_MIRROR=""
DEPLOY_AUTOSTART=""
if [ -f "$WORK_DIR/deploy.conf" ]; then
    # shellcheck source=/dev/null
    . "$WORK_DIR/deploy.conf"
    DEPLOY_TTYD_USER="${TTYD_USER:-}"; DEPLOY_TTYD_PASS="${TTYD_PASS:-}"
    DEPLOY_TTYD_PORT="${TTYD_PORT:-}"; DEPLOY_TUNNEL_MODE="${TUNNEL_MODE:-}"
    DEPLOY_TUNNEL_DOMAIN="${TUNNEL_DOMAIN:-}"; DEPLOY_TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"
    DEPLOY_TTYD_VERSION="${TTYD_VERSION:-}"; DEPLOY_CF_VERSION="${CF_VERSION:-}"
    DEPLOY_GH_MIRROR="${GH_MIRROR:-}"
    DEPLOY_AUTOSTART="${AUTOSTART:-}"
fi

# 最终值: 环境变量 > deploy.conf > 已保存凭证 > 默认值
TTYD_USER="${ENV_TTYD_USER:-${DEPLOY_TTYD_USER:-${CREDS_TTYD_USER:-openclaw}}}"
TTYD_PASS="${ENV_TTYD_PASS:-${DEPLOY_TTYD_PASS:-${CREDS_TTYD_PASS:-}}}"
TTYD_PORT_RES="${ENV_TTYD_PORT:-${DEPLOY_TTYD_PORT:-${CREDS_TTYD_PORT:-7681}}}"
TUNNEL_MODE="${ENV_TUNNEL_MODE:-${DEPLOY_TUNNEL_MODE:-${CREDS_TUNNEL_MODE:-auto}}}"
TUNNEL_DOMAIN="${ENV_TUNNEL_DOMAIN:-${DEPLOY_TUNNEL_DOMAIN:-${CREDS_TUNNEL_DOMAIN:-}}}"
TUNNEL_TOKEN="${ENV_TUNNEL_TOKEN:-${DEPLOY_TUNNEL_TOKEN:-${CREDS_TUNNEL_TOKEN:-}}}"

TTYD_VERSION="${ENV_TTYD_VERSION:-${DEPLOY_TTYD_VERSION:-$CRT_TTYD_VERSION_DEFAULT}}"
CF_VERSION="${ENV_CF_VERSION:-${DEPLOY_CF_VERSION:-$CRT_CF_VERSION_DEFAULT}}"
GH_MIRROR="${ENV_GH_MIRROR:-${DEPLOY_GH_MIRROR:-$CRT_GH_MIRROR_DEFAULT}}"
AUTOSTART="${ENV_AUTOSTART:-${DEPLOY_AUTOSTART:-yes}}"

# 密码: 未提供则自动生成随机强密码 (仅字母数字, 避免转义问题)
if [ -z "$TTYD_PASS" ]; then
    TTYD_PASS="$(crt_random_password 20)"
    echo "   已自动生成随机终端密码"
fi
case "$TTYD_PASS" in
    *:*) echo "   ⚠️  密码包含冒号(:), 可能与 ttyd 参数解析冲突, 建议改用字母数字" ;;
esac

# ttyd 子进程 shell: 优先 bash
if [ -x /bin/bash ]; then TTYD_SHELL_CHOICE="/bin/bash"; else TTYD_SHELL_CHOICE="/bin/sh"; fi

echo "   终端用户: $TTYD_USER | 端口: $TTYD_PORT_RES | 隧道模式: $TUNNEL_MODE | 自启动: $AUTOSTART"

# ============================================================
# [2/8] 依赖检查
# ============================================================
echo ""
echo "[2/8] 检查依赖..."

DOWNLOADER=""
if command -v curl >/dev/null 2>&1; then DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then DOWNLOADER="wget"
else
    echo "❌ 缺少下载工具 (curl 或 wget)"
    echo "   Ubuntu/Debian: apt update && apt install -y curl"
    echo "   CentOS/RHEL:   yum install -y curl"
    echo "   Alpine:        apk add curl"
    exit 1
fi
echo "   ✅ 下载工具: $DOWNLOADER"
if ! command -v pkill >/dev/null 2>&1; then
    echo "   ⚠️  缺少 procps (pkill), 进程清理能力受限; 建议安装: apt install -y procps"
fi

# ============================================================
# [3/8] 架构检测 + 下载二进制
# ============================================================
echo ""
echo "[3/8] 架构检测与二进制下载..."

ARCH_RAW="$(uname -m)"
ARCH_NORM="$(crt_detect_arch)" || {
    echo "❌ 不支持的架构: $ARCH_RAW (支持: x86_64 / aarch64 / armv7l / i686)"
    exit 1
}
TTYD_ASSET="$(crt_ttyd_asset "$ARCH_NORM")"
CF_ASSET="$(crt_cf_asset "$ARCH_NORM")"
echo "   ✅ 架构: $ARCH_RAW → ttyd:$TTYD_ASSET cloudflared:$CF_ASSET"

# 校验下载源: 仅允许 http/https, 拒绝 localhost / 环回 / 私有 / 保留地址
is_public_url() { crt_is_public_url "$1"; }

fetch_file() {
    local url="$1" target="$2"
    if ! is_public_url "$url"; then
        echo "   ⚠️  拒绝非公开地址下载源: $url"
        return 1
    fi
    if [ "$DOWNLOADER" = "curl" ]; then
        curl --fail --location --silent --show-error --max-time 120 -o "$target" "$url" 2>/dev/null && return 0
    else
        wget --quiet --timeout=120 -O "$target" "$url" 2>/dev/null && return 0
    fi
    return 1
}

download_with_fallback() {
    # 依次尝试: 国内镜像 → GitHub 直连
    local target="$1" gh_path="$2"
    if [ -n "$GH_MIRROR" ]; then
        fetch_file "${GH_MIRROR}/https://github.com/${gh_path}" "$target" && return 0
    fi
    fetch_file "https://github.com/${gh_path}" "$target" && return 0
    return 1
}

if [ ! -x "$TTYD_BIN" ]; then
    echo "   下载 ttyd v${TTYD_VERSION} (${TTYD_ASSET})..."
    if download_with_fallback "$TTYD_BIN" "tsl0922/ttyd/releases/download/${TTYD_VERSION}/${TTYD_ASSET}"; then
        chmod +x "$TTYD_BIN"
        if [ -s "$TTYD_BIN" ]; then echo "   ✅ ttyd 下载成功"; else echo "   ❌ ttyd 文件为空"; exit 1; fi
    else
        echo "   ❌ ttyd 下载失败 (镜像与直连均不可用)"
        echo "      可手动下载放到: $TTYD_BIN"
        echo "      https://github.com/tsl0922/ttyd/releases"
        exit 1
    fi
else
    echo "   ✅ ttyd 已存在, 跳过下载"
fi

if [ ! -x "$CF_BIN" ]; then
    echo "   下载 cloudflared v${CF_VERSION} (${CF_ASSET})..."
    if download_with_fallback "$CF_BIN" "cloudflare/cloudflared/releases/download/${CF_VERSION}/${CF_ASSET}"; then
        chmod +x "$CF_BIN"
        if [ -s "$CF_BIN" ]; then echo "   ✅ cloudflared 下载成功"; else echo "   ❌ cloudflared 文件为空"; exit 1; fi
    else
        echo "   ❌ cloudflared 下载失败 (镜像与直连均不可用)"
        echo "      可手动下载放到: $CF_BIN"
        echo "      https://github.com/cloudflare/cloudflared/releases"
        exit 1
    fi
else
    echo "   ✅ cloudflared 已存在, 跳过下载"
fi

# ============================================================
# [4/8] 停止旧进程
# ============================================================
echo ""
echo "[4/8] 停止旧进程..."

if [ -f "$PID_DIR/tunnel-daemon.pid" ]; then
    old_pid="$(cat "$PID_DIR/tunnel-daemon.pid" 2>/dev/null || true)"
    if [ -n "$old_pid" ] && ps -p "$old_pid" >/dev/null 2>&1; then
        kill "$old_pid" 2>/dev/null || true
        echo "   已停止旧守护进程 (PID: $old_pid)"
    fi
fi
command -v pkill >/dev/null 2>&1 && { pkill -x ttyd 2>/dev/null || true; pkill -x cloudflared 2>/dev/null || true; }
sleep 1
echo "   ✅ 旧进程已清理"

# ============================================================
# [5/8] 隧道模式判定与配置
# ============================================================
echo ""
echo "[5/8] 隧道配置..."

# 查找隧道凭证文件 (新名优先, 兼容旧名)
CRED_SRC=""
for f in "$WORK_DIR/tunnel-credentials.json" "$WORK_DIR/openclaw-tunnel.json"; do
    if [ -f "$f" ]; then CRED_SRC="$f"; break; fi
done

# 自动判定模式
if [ "$TUNNEL_MODE" = "auto" ]; then
    if [ -n "$TUNNEL_TOKEN" ]; then
        TUNNEL_MODE="token"
    elif [ -n "$CRED_SRC" ]; then
        TUNNEL_MODE="config"
    else
        TUNNEL_MODE="quick"
    fi
fi

# 模式可行性校验 (不可行时降级为 quick, 不中断部署)
if [ "$TUNNEL_MODE" = "token" ] && [ -z "$TUNNEL_TOKEN" ]; then
    echo "   ⚠️  token 模式缺少 TUNNEL_TOKEN, 降级为临时隧道"
    TUNNEL_MODE="quick"
fi
if [ "$TUNNEL_MODE" = "config" ]; then
    if [ -z "$CRED_SRC" ]; then
        echo "   ⚠️  config 模式缺少隧道凭证文件, 降级为临时隧道"
        TUNNEL_MODE="quick"
    elif [ -z "$TUNNEL_DOMAIN" ]; then
        echo "   ⚠️  config 模式缺少 TUNNEL_DOMAIN, 降级为临时隧道"
        echo "      (配置专属域名后重新运行本脚本即可启用)"
        TUNNEL_MODE="quick"
    fi
fi

# config 模式: 生成最终 cloudflared 配置
if [ "$TUNNEL_MODE" = "config" ]; then
    cred_dst="$HOME_DIR/.cloudflared/tunnel-credentials.json"
    cp "$CRED_SRC" "$cred_dst"
    chmod 600 "$cred_dst"
    tunnel_id="$(sed -n 's/.*"TunnelID"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$cred_dst" | head -n 1)"
    if [ -z "$tunnel_id" ]; then
        echo "   ⚠️  无法从凭证文件解析 TunnelID, 降级为临时隧道"
        TUNNEL_MODE="quick"
    else
        cfg_out="$HOME_DIR/.cloudflared/config.yml"
        template="$WORK_DIR/cloudflared-config.yml"
        if [ -f "$template" ] && grep -q '__' "$template"; then
            sed -e "s|__TUNNEL_ID__|$tunnel_id|g" \
                -e "s|__CRED_FILE__|$cred_dst|g" \
                -e "s|__DOMAIN__|$TUNNEL_DOMAIN|g" \
                -e "s|__TTYD_PORT__|$TTYD_PORT_RES|g" \
                "$template" > "$cfg_out.tmp" && mv "$cfg_out.tmp" "$cfg_out"
        elif [ -f "$template" ]; then
            cp "$template" "$cfg_out"
        else
            cat > "$cfg_out" <<EOF
tunnel: $tunnel_id
credentials-file: $cred_dst
ingress:
  - hostname: $TUNNEL_DOMAIN
    path: /terminal*
    service: http://localhost:$TTYD_PORT_RES
  - service: http_status:404
EOF
        fi
        echo "   ✅ 已生成 $cfg_out (域名: $TUNNEL_DOMAIN)"
    fi
fi

echo "   最终模式: $TUNNEL_MODE"

# ============================================================
# [6/8] 启动服务 (ttyd + cloudflared)
# ============================================================
echo ""
echo "[6/8] 启动服务..."

nohup "$TTYD_BIN" -p "$TTYD_PORT_RES" -i 127.0.0.1 -W -b /terminal -c "${TTYD_USER}:${TTYD_PASS}" "$TTYD_SHELL_CHOICE" \
    > "$LOG_DIR/ttyd.log" 2>&1 &
echo $! > "$PID_DIR/ttyd.pid"
sleep 2
if command -v pgrep >/dev/null 2>&1 && pgrep -x ttyd >/dev/null 2>&1; then
    echo "   ✅ ttyd 已启动 (端口 $TTYD_PORT_RES)"
else
    echo "   ❌ ttyd 启动失败, 查看日志: tail -20 $LOG_DIR/ttyd.log"
fi

QUICK_URL=""
case "$TUNNEL_MODE" in
    token)
        nohup "$CF_BIN" tunnel --no-autoupdate run --token "$TUNNEL_TOKEN" \
            > "$LOG_DIR/cloudflared.log" 2>&1 &
        ;;
    config)
        nohup "$CF_BIN" tunnel --no-autoupdate --config "$HOME_DIR/.cloudflared/config.yml" run \
            > "$LOG_DIR/cloudflared.log" 2>&1 &
        ;;
    quick)
        nohup "$CF_BIN" tunnel --no-autoupdate --url "http://localhost:$TTYD_PORT_RES" \
            > "$LOG_DIR/cloudflared.log" 2>&1 &
        ;;
esac
echo $! > "$PID_DIR/cloudflared.pid"
sleep 2

# 等待隧道就绪 (最多 30 秒; 不使用 seq, 兼容精简容器)
# 注意: quick 模式必须等到真实 URL 出现, 不能匹配 "Requesting..." 提示行
TUNNEL_OK="no"
i=0
while [ $i -lt 30 ]; do
    if grep -q "Registered tunnel connection" "$LOG_DIR/cloudflared.log" 2>/dev/null; then
        TUNNEL_OK="yes"; break
    fi
    if [ "$TUNNEL_MODE" = "quick" ] && grep -qE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG_DIR/cloudflared.log" 2>/dev/null; then
        TUNNEL_OK="yes"; break
    fi
    if command -v pgrep >/dev/null 2>&1 && ! pgrep -x cloudflared >/dev/null 2>&1; then
        break
    fi
    sleep 1
    i=$((i + 1))
done

if [ "$TUNNEL_MODE" = "quick" ]; then
    QUICK_URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG_DIR/cloudflared.log" 2>/dev/null | tail -n 1)"
    if [ -n "$QUICK_URL" ]; then printf '%s\n' "$QUICK_URL" > "$QUICK_URL_FILE"; fi
fi

if [ "$TUNNEL_OK" = "yes" ]; then
    echo "   ✅ cloudflared 已连接 ($TUNNEL_MODE 模式)"
else
    echo "   ❌ cloudflared 未就绪, 查看日志: tail -20 $LOG_DIR/cloudflared.log"
fi

# ============================================================
# [7/8] 启动守护进程 + 保存凭证
# ============================================================
echo ""
echo "[7/8] 守护进程与凭证..."

# 保存凭证供守护进程与重部署复用 (权限 600)
cat > "$CRED_FILE" <<EOF
# Cloud Remote Tunnel — 部署凭证 (自动生成, 请勿提交 / 请勿分享)
TTYD_USER='$TTYD_USER'
TTYD_PASS='$TTYD_PASS'
TTYD_PORT='$TTYD_PORT_RES'
TUNNEL_MODE='$TUNNEL_MODE'
TUNNEL_DOMAIN='$TUNNEL_DOMAIN'
TUNNEL_TOKEN='$TUNNEL_TOKEN'
EOF
chmod 600 "$CRED_FILE"
echo "   ✅ 凭证已保存: $CRED_FILE (600)"

DAEMON_SCRIPT="$WORK_DIR/tunnel-daemon.sh"
if [ -f "$DAEMON_SCRIPT" ]; then
    nohup bash "$DAEMON_SCRIPT" > "$LOG_DIR/daemon-output.log" 2>&1 &
    DAEMON_PID=$!
    echo "$DAEMON_PID" > "$PID_DIR/tunnel-daemon.pid"
    sleep 2
    if ps -p "$DAEMON_PID" >/dev/null 2>&1; then
        echo "   ✅ 守护进程已启动 (PID: $DAEMON_PID, 每 10 秒巡检)"
    else
        echo "   ❌ 守护进程启动失败"
    fi
else
    echo "   ⚠️  tunnel-daemon.sh 不存在, 跳过守护进程"
fi

# 自启动 (容器重启后自动恢复): 复制脚本到稳定目录 + 安装登录钩子/@reboot
AUTOSTART_STATE="未配置"
if [ "${AUTOSTART:-yes}" = "yes" ] && [ -f "$WORK_DIR/autostart.sh" ]; then
    if bash "$WORK_DIR/autostart.sh" enable > "$LOG_DIR/autostart-enable.log" 2>&1; then
        if grep -q "@reboot" "$LOG_DIR/autostart-enable.log" 2>/dev/null; then
            AUTOSTART_STATE="已启用 (crontab @reboot + 登录钩子)"
        else
            AUTOSTART_STATE="已启用 (登录钩子; 容器重启后打开终端即恢复)"
        fi
        echo "   ✅ 自启动: $AUTOSTART_STATE"
    else
        AUTOSTART_STATE="配置失败, 见 $LOG_DIR/autostart-enable.log"
        echo "   ⚠️  自启动配置失败 (可手动: bash autostart.sh enable)"
    fi
else
    AUTOSTART_STATE="已跳过 (AUTOSTART=no)"
    echo "   ℹ️  自启动未启用 (AUTOSTART=no)"
fi

# 刷新完整性清单: 把自启动副本 (app 目录) 一并纳入校验范围
if command -v crt_manifest_write_targets >/dev/null 2>&1; then
    if crt_manifest_write_targets "$STATE_DIR/deployed.sha256" "$WORK_DIR" "$HOME_DIR"; then
        echo "   ✅ 完整性清单已刷新 (含自启动副本)"
    fi
fi

# ============================================================
# [8/8] 自检 + 输出连接卡片
# ============================================================
echo ""
echo "[8/8] 自检..."

LOCAL_CHECK="✗"
if [ "$DOWNLOADER" = "curl" ]; then
    if curl -fsS --max-time 8 -u "${TTYD_USER}:${TTYD_PASS}" \
        "http://127.0.0.1:${TTYD_PORT_RES}/terminal/token" >/dev/null 2>&1; then
        LOCAL_CHECK="✓"
    fi
fi
[ "$LOCAL_CHECK" = "✗" ] && command -v pgrep >/dev/null 2>&1 && pgrep -x ttyd >/dev/null 2>&1 && LOCAL_CHECK="✓(进程)"

case "$TUNNEL_MODE" in
    quick)  CONNECT_URL="${QUICK_URL}" ;;
    *)      CONNECT_URL="https://${TUNNEL_DOMAIN}" ;;
esac

{
echo ""
echo "=============================================="
echo "  📋 连接卡片 (Connection Card)"
echo "=============================================="
echo "  模式    : $TUNNEL_MODE"
if [ "$TUNNEL_MODE" = "quick" ]; then
    echo "  ⚠️  临时隧道地址会变化, 正式使用请配置专属域名 (TUNNEL_DOMAIN)"
fi
if [ -n "$CONNECT_URL" ]; then
    echo "  地址    : ${CONNECT_URL}/terminal/"
else
    echo "  地址    : (未获取到, 查看 $LOG_DIR/cloudflared.log)"
fi
echo "  用户名  : $TTYD_USER"
echo "  密码    : $TTYD_PASS"
echo "----------------------------------------------"
if [ "$TUNNEL_OK" = "yes" ]; then
    echo "  自检: 本地终端 $LOCAL_CHECK | 隧道 ✓"
else
    echo "  自检: 本地终端 $LOCAL_CHECK | 隧道 ✗ (检查日志)"
fi
echo "  自启动: $AUTOSTART_STATE"
echo "----------------------------------------------"
echo "  本地免密连接 (在本地电脑执行, 三选一):"
echo ""
echo "  [A] 登记到 connect.json (推荐, 一次登记永久使用):"
if [ -n "$CONNECT_URL" ]; then
echo "      TUNNEL_URL='${CONNECT_URL}' TUNNEL_USER='${TTYD_USER}' TUNNEL_PASSWORD='${TTYD_PASS}' \\"
echo "        ./connect.sh --add-server myserver"
else
echo "      (等待隧道就绪后, 用相同格式登记)"
fi
echo ""
echo "  [B] 环境变量直连 (适合 AI / 脚本一次性调用):"
if [ -n "$CONNECT_URL" ]; then
echo "      TUNNEL_URL='${CONNECT_URL}' TUNNEL_USER='${TTYD_USER}' TUNNEL_PASSWORD='${TTYD_PASS}' ./connect.sh \"命令\""
fi
echo ""
echo "  [C] 纯命令行直连:"
if [ -n "$CONNECT_URL" ]; then
echo "      ./connect.sh ${CONNECT_URL} ${TTYD_USER} '${TTYD_PASS}' \"命令\""
fi
echo "----------------------------------------------"
echo "  日志: $LOG_DIR/{ttyd,cloudflared,tunnel-daemon}.log"
echo "  卡片已保存: $CARD_FILE (600, 可拷回本地保存)"
echo "=============================================="
} | tee "$CARD_FILE" >/dev/null
chmod 600 "$CARD_FILE"
# 同时打印到终端
cat "$CARD_FILE"

echo ""
if [ "$TUNNEL_OK" = "yes" ] && { [ "$LOCAL_CHECK" = "✓" ] || [ "$LOCAL_CHECK" = "✓(进程)" ]; }; then
    echo "✅ 部署成功 — 用上面的卡片信息即可远程连接终端"
else
    echo "⚠️  部署未完全就绪, 请检查上述日志"
fi
