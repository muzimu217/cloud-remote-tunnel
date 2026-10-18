#!/bin/bash
# ============================================================
# Cloud Remote Tunnel — 已部署文件完整性校验 / 只读锁定
# ============================================================
# 用途: 检测部署后的文件是否被意外修改 (例如容器内的自动化
#       工具 / AI 误改脚本), 并可选择把它们设为只读。
#
# 用法:
#   bash verify.sh           校验 (~/.cloud-remote-tunnel/deployed.sha256)
#   bash verify.sh --write   重新生成清单 (安装时已自动执行)
#   bash verify.sh --lock    设为只读 (chattr +i, 回退 chmod 555)
#   bash verify.sh --unlock  解除只读
#
# 退出码: 0 一致 | 1 有文件被修改/缺失 | 2 无清单或工具缺失
#
# 边界说明 (务必理解):
#   同一台机器上, 与部署文件同权限的进程 (尤其 root) 始终可以读写
#   这些文件, 也可以改写清单本身。因此本工具提供的是 "改动可发现",
#   而不是 "改动可阻止"; 它解决的是误改 / 误删, 不是对抗性篡改。
# ============================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="${HOME:-/root}"
STATE_DIR="$HOME_DIR/.cloud-remote-tunnel"
MANIFEST="$STATE_DIR/deployed.sha256"

# shellcheck source=lib/common.sh
if [ -f "$HERE/lib/common.sh" ]; then
    . "$HERE/lib/common.sh"
else
    echo "❌ 缺少 lib/common.sh (部署包不完整)" >&2
    exit 2
fi

usage() {
    cat <<'HLP'
用法:
  bash verify.sh           校验已部署文件 (~/.cloud-remote-tunnel/deployed.sha256)
  bash verify.sh --write   重新生成清单 (安装时已自动执行)
  bash verify.sh --lock    设为只读 (chattr +i, 回退 chmod 555)
  bash verify.sh --unlock  解除只读
退出码: 0 一致 | 1 被修改/缺失 | 2 无清单或工具缺失
HLP
}

case "${1:-}" in
    --write)
        mkdir -p "$STATE_DIR"
        if crt_manifest_write_targets "$MANIFEST" "$HERE" "$HOME_DIR"; then
            echo "✅ 已写入完整性清单: $MANIFEST"
            exit 0
        fi
        echo "❌ 写入清单失败" >&2
        exit 2
        ;;
    --lock|--unlock)
        mode="lock"
        [ "$1" = "--unlock" ] && mode="unlock"
        n=0
        while IFS= read -r f; do
            [ -f "$f" ] || continue
            if [ "$mode" = "lock" ]; then
                # chattr +i 在 overlayfs 上可能不支持, 回退到 chmod
                chattr +i "$f" 2>/dev/null || chmod 555 "$f" 2>/dev/null || true
            else
                chattr -i "$f" 2>/dev/null || true
                chmod u+w "$f" 2>/dev/null || true
            fi
            n=$((n + 1))
        done < <(crt_deploy_targets "$HERE" "$HOME_DIR")
        if [ "$mode" = "lock" ]; then
            echo "🔒 已锁定 $n 个文件为只读 (解锁: bash verify.sh --unlock)"
            echo "   注意: 锁定后重新部署前需先 --unlock, 否则部分脚本无法更新。"
        else
            echo "🔓 已解锁 $n 个文件"
        fi
        exit 0
        ;;
    ""|--check)
        out="$(crt_manifest_verify "$MANIFEST" 2>/dev/null)"
        rc=$?
        if [ "$rc" -eq 0 ]; then
            echo "✅ 已部署文件校验通过 (共 $(wc -l < "$MANIFEST" | tr -d ' ') 个文件)"
            exit 0
        fi
        if [ "$rc" -eq 2 ]; then
            echo "⚠️  未找到清单, 请先运行 install.sh, 或执行 bash verify.sh --write" >&2
            exit 2
        fi
        echo "❌ 检测到文件被修改或缺失:"
        printf '%s\n' "$out"
        echo "   恢复方法: 重新运行 bash install.sh (会先校验包再重新安装)"
        exit 1
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        echo "未知参数: $1" >&2
        usage
        exit 2
        ;;
esac
