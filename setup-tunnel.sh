#!/bin/bash
# ============================================================
# Cloud Remote Tunnel — 本地隧道自动化脚本 (在本地电脑运行)
# ============================================================
# 用途: 拿到专属域名后, 一键完成 Cloudflare 侧全部配置:
#   1) 登录 Cloudflare (仅首次, 浏览器授权)
#   2) 创建命名隧道 (已存在则复用)
#   3) 绑定专属域名 (DNS CNAME)
#   4) 生成 tunnel-credentials.json + 更新 deploy.conf
#   5) 输出隧道 Token (可选 token 模式) 与后续步骤
#
# 用法:
#   ./setup-tunnel.sh <域名> [隧道名]        # 例: ./setup-tunnel.sh tunnel.example.com
#   ./setup-tunnel.sh <域名> --token         # 额外输出 Token (token 模式部署用)
#
# 完成后: 把本目录上传到云容器, 执行 bash server-start-robust.sh
# ============================================================
set -u

WORK_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_CRED="$WORK_DIR/tunnel-credentials.json"
OUT_CONF="$WORK_DIR/deploy.conf"

DOMAIN=""
TUNNEL_NAME="cloud-remote-tunnel"
SHOW_TOKEN="no"

for arg in "$@"; do
    case "$arg" in
        --token) SHOW_TOKEN="yes" ;;
        -h|--help)
            echo "用法: $0 <域名> [隧道名] [--token]"
            echo "  例: $0 tunnel.example.com"
            exit 0
            ;;
        *)
            if [ -z "$DOMAIN" ]; then DOMAIN="$arg"
            else TUNNEL_NAME="$arg"
            fi
            ;;
    esac
done

if [ -z "$DOMAIN" ]; then
    echo "用法: $0 <域名> [隧道名] [--token]"
    echo "  例: $0 tunnel.example.com"
    exit 2
fi

# 域名基本校验
case "$DOMAIN" in
    *.*) : ;;
    *) echo "❌ 域名格式不正确: $DOMAIN (应形如 tunnel.example.com)"; exit 2 ;;
esac

# 查找 cloudflared
CF_BIN="${CLOUDFLARED:-}"
if [ -z "$CF_BIN" ]; then
    if command -v cloudflared >/dev/null 2>&1; then
        CF_BIN="$(command -v cloudflared)"
    elif [ -x "$HOME/.local/bin/cloudflared" ]; then
        CF_BIN="$HOME/.local/bin/cloudflared"
    fi
fi
if [ -z "$CF_BIN" ]; then
    echo "❌ 未找到 cloudflared。请先安装:"
    echo "   macOS:  brew install cloudflared"
    echo "   或下载: https://github.com/cloudflare/cloudflared/releases"
    exit 1
fi
echo "使用 cloudflared: $CF_BIN"

# ---------- 1) 登录 ----------
if [ ! -f "$HOME/.cloudflared/cert.pem" ]; then
    echo ""
    echo "[1/5] 登录 Cloudflare (将打开浏览器, 选择你的域名所在账号并授权)..."
    "$CF_BIN" tunnel login || { echo "❌ 登录失败"; exit 1; }
else
    echo "[1/5] 已登录 (cert.pem 存在), 跳过"
fi

# ---------- 2) 创建隧道 (幂等) ----------
echo ""
echo "[2/5] 创建/复用隧道: $TUNNEL_NAME"
TUNNEL_ID="$("$CF_BIN" tunnel list 2>/dev/null | awk -v n="$TUNNEL_NAME" '$2 == n {print $1; exit}')"
if [ -n "$TUNNEL_ID" ]; then
    echo "   已存在, 隧道 ID: $TUNNEL_ID"
else
    CREATE_OUT="$("$CF_BIN" tunnel create "$TUNNEL_NAME" 2>&1)"
    CREATE_RC=$?
    TUNNEL_ID="$(printf '%s' "$CREATE_OUT" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -n 1)"
    if [ $CREATE_RC -ne 0 ] || [ -z "$TUNNEL_ID" ]; then
        echo "$CREATE_OUT"
        echo "❌ 创建隧道失败"
        exit 1
    fi
    echo "   创建成功, 隧道 ID: $TUNNEL_ID"
fi

CRED_SRC="$HOME/.cloudflared/$TUNNEL_ID.json"
if [ ! -f "$CRED_SRC" ]; then
    echo "❌ 凭证文件不存在: $CRED_SRC"
    exit 1
fi

# ---------- 3) 绑定域名 ----------
echo ""
echo "[3/5] 绑定域名: $DOMAIN → 隧道 $TUNNEL_NAME"
ROUTE_OUT="$("$CF_BIN" tunnel route dns "$TUNNEL_ID" "$DOMAIN" 2>&1)"
if printf '%s' "$ROUTE_OUT" | grep -qiE 'already|exists'; then
    echo "   DNS 记录已存在, 跳过 (若要更改请先在 Cloudflare 控制台删除旧记录)"
elif printf '%s' "$ROUTE_OUT" | grep -qiE 'error|failed'; then
    echo "$ROUTE_OUT"
    echo "   ⚠️  绑定可能未成功, 请到 Cloudflare 控制台确认 DNS 记录"
else
    echo "   ✅ DNS 已绑定"
fi

# ---------- 4) 生成部署文件 ----------
echo ""
echo "[4/5] 生成部署文件..."
cp "$CRED_SRC" "$OUT_CRED"
chmod 600 "$OUT_CRED"
echo "   ✅ $OUT_CRED"

if [ -f "$OUT_CONF" ]; then
    # 更新已有 deploy.conf 的域名行
    if grep -q '^TUNNEL_DOMAIN=' "$OUT_CONF"; then
        awk -v d="$DOMAIN" 'BEGIN{FS=OFS="="} $1=="TUNNEL_DOMAIN" {print $1"=\""d"\""; next} {print}' "$OUT_CONF" > "$OUT_CONF.tmp" && mv "$OUT_CONF.tmp" "$OUT_CONF"
    else
        printf 'TUNNEL_DOMAIN="%s"\n' "$DOMAIN" >> "$OUT_CONF"
    fi
    # 确保 config 模式
    if grep -q '^TUNNEL_MODE=' "$OUT_CONF"; then
        awk -v m="config" 'BEGIN{FS=OFS="="} $1=="TUNNEL_MODE" {print $1"=\""m"\""; next} {print}' "$OUT_CONF" > "$OUT_CONF.tmp" && mv "$OUT_CONF.tmp" "$OUT_CONF"
    else
        printf 'TUNNEL_MODE="config"\n' >> "$OUT_CONF"
    fi
else
    cat > "$OUT_CONF" <<EOF
# 由 setup-tunnel.sh 生成
TTYD_USER="openclaw"
TTYD_PASS=""
TUNNEL_MODE="config"
TUNNEL_DOMAIN="$DOMAIN"
EOF
    chmod 600 "$OUT_CONF"
fi
echo "   ✅ $OUT_CONF (模式: config, 域名: $DOMAIN)"

# ---------- 5) 输出后续步骤 ----------
echo ""
echo "[5/5] 完成"
echo ""
echo "=============================================="
echo "  隧道信息"
echo "=============================================="
echo "  隧道名  : $TUNNEL_NAME"
echo "  隧道 ID : $TUNNEL_ID"
echo "  域名    : https://$DOMAIN/terminal/"
echo "  凭证    : $OUT_CRED (含密钥, 勿提交/分享)"
echo "=============================================="

if [ "$SHOW_TOKEN" = "yes" ]; then
    echo ""
    echo "  隧道 Token (token 模式部署用; 路由规则需在 Cloudflare 控制台配置):"
    "$CF_BIN" tunnel token "$TUNNEL_ID"
fi

echo ""
echo "后续步骤:"
echo "  1. 将本目录 (含 tunnel-credentials.json, deploy.conf, cloudflared-config.yml,"
echo "     server-start-robust.sh, tunnel-daemon.sh) 上传到云容器"
echo "  2. 在云容器执行: bash server-start-robust.sh"
echo "  3. 本地执行: ./connect.sh --add-server myserver   (按连接卡片提示)"
