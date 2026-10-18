#!/bin/bash
# ============================================================
# Cloud Remote Tunnel — 离线部署包 · 一键安装 (在目标服务器上运行)
# ============================================================
# 解压压缩包后执行:   bash install.sh
#
# 本脚本全部内容明文可读, 只做三件事:
#   1) 校验包内文件完整性 (SHA256)
#   2) 将 ttyd / cloudflared 安装到 ~/.local/bin   (全程无需联网)
#   3) 调用 server-start-robust.sh 启动全部服务, 输出"连接卡片"
#
# 可选:
#   bash install.sh --help      查看本说明
#   bash uninstall.sh [--purge] 干净卸载
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

# 公共函数库 (离线包内位于 lib/common.sh)
# shellcheck source=lib/common.sh
if [ -f "$HERE/lib/common.sh" ]; then . "$HERE/lib/common.sh"; fi

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'HLP'
用法: bash install.sh [--no-autostart]
  - 校验包完整性, 安装 ttyd/cloudflared 到 ~/.local/bin, 并自动启动服务
  - 启动完成后输出"连接卡片"(访问地址 / 用户名 / 密码)
  - 安装后自动配置自启动 (容器重启后打开终端即恢复; --no-autostart 可关闭)
  - 安装后会生成完整性清单, 可用 bash verify.sh 检测部署文件是否被改动
预配置: cp deploy.conf.example deploy.conf 并修改后重跑本脚本
防误改: bash verify.sh --lock   (设为只读) / bash verify.sh --unlock (解锁)
自启动: bash autostart.sh status | enable | disable   (或 AUTOSTART=no 环境变量)
卸载:   bash uninstall.sh [--purge]
HLP
    exit 0
fi

# --no-autostart: 透传给 server-start-robust.sh
NO_AUTOSTART="no"
case "${1:-}" in
    --no-autostart) NO_AUTOSTART="yes" ;;
esac

if ! command -v bash >/dev/null 2>&1; then
    echo "❌ 未找到 bash, 请先安装 (Debian/Ubuntu: apt install -y bash)"
    exit 1
fi

echo "=============================================="
echo "  Cloud Remote Tunnel — 离线部署 (解压即启动)"
echo "=============================================="

# ---- 1) 架构匹配检查 ----
if command -v crt_detect_arch >/dev/null 2>&1; then
    ARCH="$(crt_detect_arch)" || { echo "❌ 不支持的架构: $(uname -m)"; exit 1; }
    EXPECT="linux-$ARCH"
else
    # 兜底: lib/common.sh 缺失时保持原有行为
    case "$(uname -m)" in
        x86_64|amd64)  EXPECT="linux-amd64" ;;
        aarch64|arm64) EXPECT="linux-arm64" ;;
        *) echo "❌ 不支持的架构: $(uname -m)"; exit 1 ;;
    esac
fi
BUNDLE_ARCH="$(cat "$HERE/.arch" 2>/dev/null || echo "")"
if [ -n "$BUNDLE_ARCH" ] && [ "$BUNDLE_ARCH" != "$EXPECT" ]; then
    echo "❌ 架构不匹配: 部署包为 $BUNDLE_ARCH, 本机为 $EXPECT"
    echo "   请使用与本机架构对应的部署包。"
    exit 1
fi
for f in bin/ttyd bin/cloudflared; do
    [ -s "$HERE/$f" ] || { echo "❌ 包内缺少文件: $f (请重新制作/获取完整包)"; exit 1; }
done
echo "✅ 架构匹配: $EXPECT"

# ---- 2) 完整性校验 (SHA256) ----
HASH_CMD=""
if command -v crt_hash_cmd >/dev/null 2>&1; then
    HASH_CMD="$(crt_hash_cmd)" || HASH_CMD=""
else
    if command -v sha256sum >/dev/null 2>&1; then HASH_CMD="sha256sum"
    elif command -v shasum >/dev/null 2>&1; then HASH_CMD="shasum -a 256"
    fi
fi

if [ -n "$HASH_CMD" ] && [ -s "$HERE/SHA256SUMS" ]; then
    bad=0
    while read -r expect rel; do
        rel="${rel#\*}"
        rel="${rel#./}"
        [ -n "$expect" ] || continue
        [ -f "$HERE/$rel" ] || { echo "  ❌ 缺文件: $rel"; bad=1; continue; }
        # shellcheck disable=SC2086  # HASH_CMD 需按空格拆分
        actual="$($HASH_CMD "$HERE/$rel" | awk '{print $1}')"
        if [ "$expect" != "$actual" ]; then
            echo "  ❌ 校验失败: $rel"
            bad=1
        fi
    done < "$HERE/SHA256SUMS"
    if [ "$bad" -ne 0 ]; then
        echo "❌ 完整性校验未通过, 已终止 (文件可能损坏或被人为修改)"
        exit 1
    fi
    echo "✅ 完整性校验通过"
else
    echo "⚠️  未找到校验工具或清单, 跳过完整性校验"
fi

# ---- 3) 安装二进制 (无需联网) ----
mkdir -p "$HOME/.local/bin"
cp -f "$HERE/bin/ttyd" "$HOME/.local/bin/ttyd"
cp -f "$HERE/bin/cloudflared" "$HOME/.local/bin/cloudflared"
chmod +x "$HOME/.local/bin/ttyd" "$HOME/.local/bin/cloudflared"
echo "✅ 二进制已安装到 ~/.local/bin (ttyd / cloudflared)"

# ---- 4) 生成完整性清单 (供 verify.sh / 守护进程检测误改) ----
if command -v crt_manifest_write_targets >/dev/null 2>&1; then
    mkdir -p "$HOME/.cloud-remote-tunnel"
    if crt_manifest_write_targets "$HOME/.cloud-remote-tunnel/deployed.sha256" "$HERE" "$HOME"; then
        echo "✅ 已生成完整性清单 (~/.cloud-remote-tunnel/deployed.sha256)"
        echo "   之后可随时用 'bash verify.sh' 检测部署文件是否被修改"
    fi
fi

# ---- 5) 启动 ----
echo ""
echo ">>> 开始启动服务..."
echo ""
if [ "$NO_AUTOSTART" = "yes" ]; then
    export AUTOSTART=no
    echo "已禁用自启动 (--no-autostart)"
fi
exec bash "$HERE/server-start-robust.sh"
