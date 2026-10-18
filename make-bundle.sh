#!/bin/bash
# ============================================================
# Cloud Remote Tunnel — 离线部署包制作脚本 (在本地电脑运行)
# ============================================================
# 生成"解压即启动"的离线包: 内含目标架构的 ttyd / cloudflared
# 二进制与全部部署脚本; 服务器无需联网即可一键部署。
#
# 用法:
#   ./make-bundle.sh                        # 默认打 linux-amd64
#   ./make-bundle.sh --arch arm64           # 打 linux-arm64
#   ./make-bundle.sh --all                  # amd64 + arm64 各一份
#   ./make-bundle.sh --config deploy.conf   # 附带部署配置 (凭证字段默认剔除)
#   ./make-bundle.sh --allow-secrets        # 允许凭证进包 (高风险, 仅供自用)
#
# 产物: dist/crt-bundle-<版本>-linux-<架构>.tar.gz  (+ .sha256 校验文件)
#
# 设计说明 (与安全相关, 请阅读):
#   * 包内所有脚本明文可读、带注释 —— 不做混淆; "看得懂"才不会被当成威胁;
#   * 默认不含任何凭证; 每个部署在首次运行时自动生成独立凭证;
#   * 请勿把包含你个人凭证的包分发给他人; 也避免多台服务器共用同一套凭证。
# ============================================================
set -u

WORK_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$WORK_DIR/dist"
BUILD_DIR="$WORK_DIR/build"

# 公共函数库: 版本号 / 架构映射 / URL 校验 / 哈希 的单一来源
# shellcheck source=lib/common.sh
. "$WORK_DIR/lib/common.sh"

VERSION="$CRT_VERSION"
GH_MIRROR="${GH_MIRROR:-$CRT_GH_MIRROR_DEFAULT}"
TTYD_VERSION="${TTYD_VERSION:-$CRT_TTYD_VERSION_DEFAULT}"
CF_VERSION="${CF_VERSION:-$CRT_CF_VERSION_DEFAULT}"

ARCHES=""
CONFIG_FILE=""
ALLOW_SECRETS="no"

usage() {
    cat <<'HLP'
用法:
  ./make-bundle.sh                        # 默认打 linux-amd64
  ./make-bundle.sh --arch arm64           # 打 linux-arm64
  ./make-bundle.sh --all                  # amd64 + arm64 各一份
  ./make-bundle.sh --config deploy.conf   # 附带部署配置 (凭证字段默认剔除)
  ./make-bundle.sh --allow-secrets        # 允许凭证进包 (高风险, 仅供自用)
HLP
}

while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCHES="$ARCHES ${2:-}"; shift 2 ;;
        --all)  ARCHES="amd64 arm64"; shift ;;
        --config) CONFIG_FILE="${2:-}"; shift 2 ;;
        --allow-secrets) ALLOW_SECRETS="yes"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数: $1"; usage; exit 2 ;;
    esac
done
[ -n "$ARCHES" ] || ARCHES="amd64"

if ! command -v curl >/dev/null 2>&1; then
    echo "❌ 本机需要 curl"
    exit 1
fi

# 校验下载源: 仅允许 http/https, 拒绝环回/私有地址 (与部署脚本同一策略)
is_public_url() { crt_is_public_url "$1"; }

fetch_file() {
    local url="$1" target="$2"
    if ! is_public_url "$url"; then
        echo "   ⚠️  拒绝非公开地址: $url"
        return 1
    fi
    curl --fail --location --silent --show-error --max-time 300 -o "$target" "$url"
}

fetch_with_mirror() {
    local target="$1" gh_path="$2"
    if [ -n "$GH_MIRROR" ] && fetch_file "${GH_MIRROR}/https://github.com/${gh_path}" "$target"; then
        return 0
    fi
    fetch_file "https://github.com/${gh_path}" "$target"
}

# 下载 + 格式校验: 镜像可能返回 HTTP 200 的 HTML 错误页或半截文件,
# curl 会视为成功; 必须校验 ELF 才允许进入打包流程。
fetch_binary() {
    local target="$1" gh_path="$2"
    if ! fetch_with_mirror "$target" "$gh_path"; then
        return 1
    fi
    if ! crt_validate_binary "$target"; then
        echo "   ⚠️  下载内容不是有效的可执行文件 (大小 $(wc -c < "$target" 2>/dev/null || echo 0) 字节), 拒绝使用"
        rm -f "$target"
        return 1
    fi
    return 0
}

build_one() {
    local arch="$1" ttyd_asset cf_asset
    if ! crt_ttyd_asset "$arch" >/dev/null 2>&1; then
        echo "❌ 不支持的架构: $arch (支持 amd64 / arm64 / armv7 / 386)"; return 1
    fi
    ttyd_asset="$(crt_ttyd_asset "$arch")"
    cf_asset="$(crt_cf_asset "$arch")"

    local f
    for f in server-start-robust.sh tunnel-daemon.sh install.sh uninstall.sh verify.sh autostart.sh resume.sh deploy.conf.example cloudflared-config.yml README-BUNDLE.md lib/common.sh; do
        [ -s "$WORK_DIR/$f" ] || { echo "❌ 缺少源文件: $f"; return 1; }
    done

    local name="crt-bundle-${VERSION}-linux-${arch}"
    local stage="$BUILD_DIR/$name"
    rm -rf "$stage"
    mkdir -p "$stage/bin" "$stage/lib"

    echo "[$arch] 下载 ttyd v$TTYD_VERSION ..."
    if ! fetch_binary "$stage/bin/ttyd" "tsl0922/ttyd/releases/download/${TTYD_VERSION}/${ttyd_asset}"; then
        echo "❌ ttyd 下载失败"; return 1
    fi
    echo "  ✅ ttyd $(du -h "$stage/bin/ttyd" | awk '{print $1}')"

    echo "[$arch] 下载 cloudflared v$CF_VERSION ..."
    if ! fetch_binary "$stage/bin/cloudflared" "cloudflare/cloudflared/releases/download/${CF_VERSION}/${cf_asset}"; then
        echo "❌ cloudflared 下载失败"; return 1
    fi
    echo "  ✅ cloudflared $(du -h "$stage/bin/cloudflared" | awk '{print $1}')"

    chmod +x "$stage/bin/ttyd" "$stage/bin/cloudflared"

    cp "$WORK_DIR/server-start-robust.sh"  "$stage/"
    cp "$WORK_DIR/tunnel-daemon.sh"        "$stage/"
    cp "$WORK_DIR/install.sh"              "$stage/"
    cp "$WORK_DIR/uninstall.sh"            "$stage/"
    cp "$WORK_DIR/verify.sh"               "$stage/"
    cp "$WORK_DIR/autostart.sh"            "$stage/"
    cp "$WORK_DIR/resume.sh"               "$stage/"
    cp "$WORK_DIR/deploy.conf.example"     "$stage/"
    cp "$WORK_DIR/cloudflared-config.yml"  "$stage/"
    cp "$WORK_DIR/README-BUNDLE.md"        "$stage/README.md"
    cp "$WORK_DIR/lib/common.sh"           "$stage/lib/common.sh"
    chmod +x "$stage/install.sh" "$stage/uninstall.sh" "$stage/verify.sh" \
             "$stage/autostart.sh" "$stage/resume.sh" \
             "$stage/server-start-robust.sh" "$stage/tunnel-daemon.sh"
    printf 'linux-%s\n' "$arch" > "$stage/.arch"

    # 可选: 附带部署配置
    if [ -n "$CONFIG_FILE" ]; then
        if [ ! -f "$CONFIG_FILE" ]; then
            echo "❌ 配置不存在: $CONFIG_FILE"; return 1
        fi
        if grep -qE '^(TTYD_PASS|TUNNEL_TOKEN)=".+"' "$CONFIG_FILE" && [ "$ALLOW_SECRETS" != "yes" ]; then
            echo "   ⚠️ 检测到配置含凭证字段, 默认剔除(置空)后入包"
            echo "      (如确需包含请加 --allow-secrets, 仅限'包只交到你自己手里'的场景)"
            grep -vE '^(TTYD_PASS|TUNNEL_TOKEN)=' "$CONFIG_FILE" > "$stage/deploy.conf"
            printf 'TTYD_PASS=""\nTUNNEL_TOKEN=""\n' >> "$stage/deploy.conf"
        else
            cp "$CONFIG_FILE" "$stage/deploy.conf"
        fi
        chmod 600 "$stage/deploy.conf"
    fi

    # 清单与校验 (兼容 macOS/精简 Linux, 不依赖 sha256sum -c)
    local HC
    HC="$(crt_hash_cmd)" || { echo "❌ 本机缺少 sha256sum / shasum, 无法生成校验清单"; return 1; }
    # shellcheck disable=SC2086  # HC 需按空格拆分为命令+参数
    ( cd "$stage" && find . -type f ! -name SHA256SUMS -exec $HC {} \; | LC_ALL=C sort -k2 > SHA256SUMS )

    # 打包
    mkdir -p "$DIST_DIR"
    tar -czf "$DIST_DIR/$name.tar.gz" -C "$BUILD_DIR" "$name"
    # shellcheck disable=SC2086
    ( cd "$DIST_DIR" && $HC "$name.tar.gz" > "$name.tar.gz.sha256" )
    local size
    size="$(du -h "$DIST_DIR/$name.tar.gz" | awk '{print $1}')"
    echo "✅ 已生成: dist/$name.tar.gz ($size)"

    rm -rf "$stage"
    return 0
}

mkdir -p "$BUILD_DIR" "$DIST_DIR"
ok="yes"
for a in $ARCHES; do
    build_one "$a" || ok="no"
done
rmdir "$BUILD_DIR" 2>/dev/null || true

echo ""
if [ "$ok" = "yes" ]; then
    echo "=============================================="
    echo "  ✅ 打包完成  →  $DIST_DIR"
    echo "=============================================="
    echo "服务器端部署 (无需联网):"
    echo "  tar xzf crt-bundle-*.tar.gz"
    echo "  cd crt-bundle-* && bash install.sh"
fi
