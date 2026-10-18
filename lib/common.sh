#!/bin/bash
# ============================================================
# Cloud Remote Tunnel — 公共函数库
# ============================================================
# 被 server-start-robust.sh / make-bundle.sh / install.sh 等
# source 引用, 集中放置重复逻辑, 避免多处实现漂移。
#
# 约定: 本文件只定义函数与常量, 不产生副作用 (不打印、不退出、
#       不修改调用者的变量命名空间以外的状态)。
# ============================================================

# ---- 版本 (单一来源) ----
# 升级版本只需改这里; make-bundle.sh 与部署脚本都从这里读。
# shellcheck disable=SC2034  # 供 source 本文件的脚本使用
CRT_VERSION="3.1.0"

# 二进制默认版本
# shellcheck disable=SC2034
CRT_TTYD_VERSION_DEFAULT="1.7.7"
# shellcheck disable=SC2034
CRT_CF_VERSION_DEFAULT="2026.10.1"
# shellcheck disable=SC2034
CRT_GH_MIRROR_DEFAULT="https://gh-proxy.com"

# ---------------------------------------------------------------
# 架构检测
# ---------------------------------------------------------------
# 输出规范架构名: amd64 / arm64 / armv7 / 386
# 未识别时返回 1 并输出空字符串
crt_detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   printf 'amd64' ;;
        aarch64|arm64)  printf 'arm64' ;;
        armv7l|armv7|armhf) printf 'armv7' ;;
        i386|i686)      printf '386' ;;
        *) return 1 ;;
    esac
}

# 由规范架构名取 ttyd 发布资产名
crt_ttyd_asset() {
    case "$1" in
        amd64)  printf 'ttyd.x86_64' ;;
        arm64)  printf 'ttyd.aarch64' ;;
        armv7)  printf 'ttyd.armhf' ;;
        386)    printf 'ttyd.i686' ;;
        *) return 1 ;;
    esac
}

# 由规范架构名取 cloudflared 发布资产名
crt_cf_asset() {
    case "$1" in
        amd64)  printf 'cloudflared-linux-amd64' ;;
        arm64)  printf 'cloudflared-linux-arm64' ;;
        armv7)  printf 'cloudflared-linux-armhf' ;;
        386)    printf 'cloudflared-linux-386' ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------
# 下载源安全校验
# ---------------------------------------------------------------
# 仅允许 http/https 且主机为公网地址; 拒绝环回 / 私有 / 保留地址。
# 用途: 防止被诱导从内网或本地地址拉取可执行文件。
crt_is_public_url() {
    local url="$1" rest host
    case "$url" in
        http://*|https://*) : ;;
        *) return 1 ;;
    esac
    # 去掉 scheme 与 userinfo
    rest="$(printf '%s' "$url" | sed -E 's#^[a-z]+://##; s#^[^@/]*@##')"
    case "$rest" in
        \[*\]:*|\[*\]) host="$(printf '%s' "$rest" | sed -E 's#^\[([^]]*)\].*#\1#')" ;;
        *)             host="$(printf '%s' "$rest" | sed -E 's#[/:?].*$##')" ;;
    esac
    host="$(printf '%s' "$host" | tr 'A-Z' 'a-z')"
    # 去掉 IPv6 可能残留的方括号, 统一比较
    host="${host#[}"
    host="${host%]}"
    case "$host" in
        ""|localhost|*.localhost|*.local|*.internal) return 1 ;;
        127.*|10.*|192.168.*|169.254.*|0.*) return 1 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 1 ;;
    esac
    # IPv6 环回 / 链路本地 / ULA / IPv4 映射
    case "$host" in
        ::1|::|fe80:*|fc00:*|fd*|::ffff:*) return 1 ;;
    esac
    # 空主机名或纯括号
    [ -n "$host" ] || return 1
    return 0
}

# ---------------------------------------------------------------
# 哈希工具
# ---------------------------------------------------------------
# 输出可用的哈希命令 (含参数), 例如 "sha256sum" 或 "shasum -a 256"
# 两者都不可用时返回 1
crt_hash_cmd() {
    if command -v sha256sum >/dev/null 2>&1; then
        printf 'sha256sum'
    elif command -v shasum >/dev/null 2>&1; then
        printf 'shasum -a 256'
    else
        return 1
    fi
}

# 计算单个文件的 sha256 (只输出十六进制串)
crt_sha256() {
    local hc
    hc="$(crt_hash_cmd)" || return 1
    # shellcheck disable=SC2086  # hc 需要按空格拆分为命令+参数
    $hc "$1" | awk '{print $1}'
}

# ---------------------------------------------------------------
# 随机密码
# ---------------------------------------------------------------
# 生成指定长度的字母数字密码 (默认 20)。
# LC_ALL=C 强制字节级处理, 否则 macOS 的 tr 会因 UTF-8 解码报非法字节序列。
crt_random_password() {
    local len="${1:-20}" pw
    pw="$(head -c 256 /dev/urandom 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c "$len")"
    if [ -z "$pw" ]; then
        # 兜底: 环境缺少 /dev/urandom 或 tr 异常时用时间+随机数
        pw="crt-$(date +%s)-$(awk 'BEGIN{srand();printf "%06d",rand()*1000000}')"
    fi
    printf '%s' "$pw"
}

# ---------------------------------------------------------------
# 进程与日志
# ---------------------------------------------------------------
# 日志超过阈值时截断, 只保留尾部指定字节数
# 用法: crt_trim_log <文件> [阈值字节=5242880] [保留字节=1048576]
crt_trim_log() {
    local f="$1" max="${2:-5242880}" keep="${3:-1048576}" size
    [ -f "$f" ] || return 0
    size=$(wc -c < "$f" 2>/dev/null || echo 0)
    [ "$size" -gt "$max" ] || return 0
    tail -c "$keep" "$f" > "$f.tmp" 2>/dev/null || { rm -f "$f.tmp"; return 1; }
    mv "$f.tmp" "$f"
    return 0
}

# ---------------------------------------------------------------
# 输出辅助
# ---------------------------------------------------------------
crt_ok()   { printf '   \033[32m✅\033[0m %s\n' "$*"; }
crt_warn() { printf '   \033[33m⚠️\033[0m  %s\n' "$*"; }
crt_err()  { printf '   \033[31m❌\033[0m %s\n' "$*" >&2; }

# ---------------------------------------------------------------
# 已部署文件完整性 (防误改)
# ---------------------------------------------------------------
# 部署完成后由 install.sh 写入清单; verify.sh 与守护进程用清单检测
# 文件是否被意外修改。注意: 同权限进程始终可以改写这些文件与清单,
# 因此这是 "改动可发现", 不是 "改动可阻止"。

# 列出应受保护的文件 (绝对路径, 每行一个)
# 用法: crt_deploy_targets <部署包目录> <HOME>
crt_deploy_targets() {
    local here="$1" home="$2" f
    printf '%s\n' "$home/.local/bin/ttyd" "$home/.local/bin/cloudflared"
    for f in server-start-robust.sh tunnel-daemon.sh install.sh uninstall.sh verify.sh autostart.sh resume.sh; do
        [ -f "$here/$f" ] && printf '%s\n' "$here/$f"
    done
    [ -f "$here/lib/common.sh" ] && printf '%s\n' "$here/lib/common.sh"
    # 自启动运行时副本 (由 autostart.sh enable 部署)
    for f in "$home/.cloud-remote-tunnel/app/resume.sh" \
             "$home/.cloud-remote-tunnel/app/tunnel-daemon.sh" \
             "$home/.cloud-remote-tunnel/app/lib/common.sh"; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
    return 0
}

# 写入清单: 用法 crt_manifest_write <清单> <文件>...
crt_manifest_write() {
    local manifest="$1"; shift
    local hc f
    hc="$(crt_hash_cmd)" || return 1
    : > "$manifest" || return 1
    for f in "$@"; do
        [ -f "$f" ] || continue
        # shellcheck disable=SC2086  # hc 需按空格拆分为命令+参数
        printf '%s  %s\n' "$($hc "$f" | awk '{print $1}')" "$f" >> "$manifest"
    done
    [ -s "$manifest" ]
}

# 按标准目标列表直接写入清单 (install.sh / verify.sh --write 使用)
crt_manifest_write_targets() {
    local manifest="$1" here="$2" home="$3"
    local hc f
    hc="$(crt_hash_cmd)" || return 1
    : > "$manifest" || return 1
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        # shellcheck disable=SC2086
        printf '%s  %s\n' "$($hc "$f" | awk '{print $1}')" "$f" >> "$manifest"
    done < <(crt_deploy_targets "$here" "$home")
    [ -s "$manifest" ]
}

# 校验清单: 输出 "被修改: x" / "缺失: x", 无问题时无输出
# 返回 0 一致 | 1 有改动 | 2 清单缺失或工具缺失
crt_manifest_verify() {
    local manifest="$1" hc bad=0 expect rel actual
    [ -f "$manifest" ] || return 2
    hc="$(crt_hash_cmd)" || return 2
    while read -r expect rel; do
        [ -n "$expect" ] || continue
        [ -n "$rel" ] || continue
        if [ ! -f "$rel" ]; then
            printf '缺失: %s\n' "$rel"
            bad=1
            continue
        fi
        # shellcheck disable=SC2086
        actual="$($hc "$rel" | awk '{print $1}')"
        if [ "$expect" != "$actual" ]; then
            printf '被修改: %s\n' "$rel"
            bad=1
        fi
    done < "$manifest"
    return $bad
}
