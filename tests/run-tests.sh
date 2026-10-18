#!/bin/bash
# ============================================================
# Cloud Remote Tunnel — 测试套件
# ============================================================
# 纯本地运行, 不依赖网络、不需要真实服务器。
# 覆盖: 公共库函数 / 脚本语法 / 参数解析 / 打包完整性 / 文档一致性
#
# 用法:
#   bash tests/run-tests.sh            # 全部测试
#   bash tests/run-tests.sh --verbose  # 显示每个用例
#
# 退出码: 0 全部通过 | 1 有失败
# ============================================================
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERBOSE="no"
[ "${1:-}" = "--verbose" ] && VERBOSE="yes"

PASS=0
FAIL=0
FAILED_NAMES=""

ok() {
    PASS=$((PASS + 1))
    [ "$VERBOSE" = "yes" ] && printf '  \033[32m✓\033[0m %s\n' "$1"
    return 0
}

bad() {
    FAIL=$((FAIL + 1))
    FAILED_NAMES="$FAILED_NAMES
  - $1: $2"
    printf '  \033[31m✗\033[0m %s — %s\n' "$1" "$2"
}

# 断言: 相等
assert_eq() {
    local name="$1" expect="$2" actual="$3"
    if [ "$expect" = "$actual" ]; then ok "$name"; else bad "$name" "期望 [$expect], 实际 [$actual]"; fi
}

# 断言: 命令成功
assert_ok() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name" "命令失败: $*"; fi
}

# 断言: 命令失败
assert_fail() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then bad "$name" "本应失败但成功了: $*"; else ok "$name"; fi
}

section() {
    printf '\n\033[1m%s\033[0m\n' "$1"
}

# 生成一个"看起来像 Linux 可执行文件"的占位物:
# ELF magic + 指定体积的零填充。用于测试夹具, 不依赖真实下载。
# 用法: make_fake_elf <路径> [总字节数]
make_fake_elf() {
    local p="$1" size="${2:-600000}"
    printf '\177ELF' > "$p"
    if command -v head >/dev/null 2>&1; then
        head -c "$size" /dev/zero >> "$p" 2>/dev/null
    fi
    chmod +x "$p"
}

# ---------------------------------------------------------------
section "1. Shell 语法检查"
# ---------------------------------------------------------------
for f in "$ROOT"/*.sh "$ROOT"/lib/*.sh "$ROOT"/tests/*.sh; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    if bash -n "$f" 2>/dev/null; then ok "语法 $name"; else bad "语法 $name" "bash -n 失败"; fi
done

# ---------------------------------------------------------------
section "2. Python 语法检查"
# ---------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
    if python3 -m py_compile "$ROOT/connect.py" 2>/dev/null; then
        ok "connect.py 语法"
    else
        bad "connect.py 语法" "py_compile 失败"
    fi
else
    bad "python3 可用性" "未安装 python3"
fi

# ---------------------------------------------------------------
section "3. 公共库函数"
# ---------------------------------------------------------------
# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"

assert_eq "版本号已定义" "yes" "$([ -n "$CRT_VERSION" ] && echo yes || echo no)"
assert_eq "默认 ttyd 版本" "1.7.7" "$CRT_TTYD_VERSION_DEFAULT"

# 架构映射 (不依赖本机实际架构)
assert_eq "ttyd 资产 amd64" "ttyd.x86_64" "$(crt_ttyd_asset amd64)"
assert_eq "ttyd 资产 arm64" "ttyd.aarch64" "$(crt_ttyd_asset arm64)"
assert_eq "ttyd 资产 armv7" "ttyd.armhf" "$(crt_ttyd_asset armv7)"
assert_eq "ttyd 资产 386"   "ttyd.i686"  "$(crt_ttyd_asset 386)"
assert_eq "cf 资产 amd64"   "cloudflared-linux-amd64" "$(crt_cf_asset amd64)"
assert_eq "cf 资产 arm64"   "cloudflared-linux-arm64" "$(crt_cf_asset arm64)"
assert_eq "cf 资产 armv7"   "cloudflared-linux-armhf" "$(crt_cf_asset armv7)"
assert_eq "cf 资产 386"     "cloudflared-linux-386"   "$(crt_cf_asset 386)"
assert_fail "未知架构被拒绝" crt_ttyd_asset mips

# 本机架构应能识别
if crt_detect_arch >/dev/null 2>&1; then ok "本机架构可识别"; else bad "本机架构可识别" "crt_detect_arch 返回非 0"; fi

# URL 安全校验
assert_ok   "允许 https 公网"   crt_is_public_url "https://github.com/x"
assert_ok   "允许 http 公网"    crt_is_public_url "http://example.com/x"
assert_fail "拒绝 localhost"    crt_is_public_url "http://localhost/x"
assert_fail "拒绝 127.0.0.1"    crt_is_public_url "http://127.0.0.1/x"
assert_fail "拒绝 10.x"         crt_is_public_url "https://10.1.2.3/x"
assert_fail "拒绝 192.168.x"    crt_is_public_url "https://192.168.1.1/x"
assert_fail "拒绝 172.16.x"     crt_is_public_url "https://172.16.0.1/x"
assert_fail "拒绝 169.254.x"    crt_is_public_url "https://169.254.1.1/x"
assert_fail "拒绝非 http 协议"  crt_is_public_url "ftp://example.com/x"
assert_fail "拒绝 IPv6 环回"    crt_is_public_url "http://[::1]/x"
assert_fail "拒绝 IPv6 ULA"     crt_is_public_url "http://[fd00::1]/x"
assert_ok   "允许 userinfo URL" crt_is_public_url "https://user:pass@example.com/x"

# 密码生成
PW="$(crt_random_password 16)"
assert_eq "密码长度 16" "16" "$(printf '%s' "$PW" | wc -c | tr -d ' ')"
if printf '%s' "$PW" | grep -qE '^[A-Za-z0-9]+$'; then ok "密码仅字母数字"; else bad "密码仅字母数字" "含其他字符: $PW"; fi
PW2="$(crt_random_password 16)"
if [ "$PW" != "$PW2" ]; then ok "密码随机性"; else bad "密码随机性" "两次生成相同"; fi

# 哈希
assert_ok "哈希命令可用" crt_hash_cmd
HASH_A="$(crt_sha256 "$ROOT/README.md")"
if printf '%s' "$HASH_A" | grep -qE '^[0-9a-f]{64}$'; then ok "sha256 格式正确"; else bad "sha256 格式正确" "得到 [$HASH_A]"; fi

# 日志截断
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
head -c 200000 /dev/zero | tr '\0' 'x' > "$TMPD/big.log"
crt_trim_log "$TMPD/big.log" 100000 10000
NEWSIZE=$(wc -c < "$TMPD/big.log" | tr -d ' ')
if [ "$NEWSIZE" -le 10001 ]; then ok "日志截断生效"; else bad "日志截断生效" "截断后仍有 $NEWSIZE 字节"; fi

# 小日志不应被改动
printf 'small\n' > "$TMPD/small.log"
crt_trim_log "$TMPD/small.log" 100000 10000
assert_eq "小日志不截断" "6" "$(wc -c < "$TMPD/small.log" | tr -d ' ')"

# ---- 完整性清单 (防误改) ----
mkdir -p "$TMPD/mf"
printf 'aaa\n' > "$TMPD/mf/a.txt"
printf 'bbb\n' > "$TMPD/mf/b.txt"
MANIFEST="$TMPD/mf/deployed.sha256"
assert_ok "清单写入成功" crt_manifest_write "$MANIFEST" "$TMPD/mf/a.txt" "$TMPD/mf/b.txt"

ISSUES="$(crt_manifest_verify "$MANIFEST")"
assert_eq "未改动时校验无输出" "" "$ISSUES"
assert_ok "未改动时返回 0" crt_manifest_verify "$MANIFEST"

# 篡改一个文件 -> 必须被发现
printf 'ccc\n' >> "$TMPD/mf/a.txt"
ISSUES="$(crt_manifest_verify "$MANIFEST" || true)"
case "$ISSUES" in
    *"被修改: $TMPD/mf/a.txt"*) ok "篡改被检出" ;;
    *) bad "篡改被检出" "输出: $ISSUES" ;;
esac
assert_fail "篡改时返回非 0" crt_manifest_verify "$MANIFEST"

# 删除一个文件 -> 报告"缺失"
rm -f "$TMPD/mf/b.txt"
ISSUES="$(crt_manifest_verify "$MANIFEST" || true)"
case "$ISSUES" in
    *"缺失: $TMPD/mf/b.txt"*) ok "缺失被检出" ;;
    *) bad "缺失被检出" "输出: $ISSUES" ;;
esac

# 清单不存在 -> 返回 2
assert_fail "清单缺失时返回非 0" crt_manifest_verify "$TMPD/mf/nonexistent.sha256"

# 部署目标列表必须包含二进制与关键脚本
TARGETS="$(crt_deploy_targets "$ROOT" "/home/testuser")"
case "$TARGETS" in
    *"/home/testuser/.local/bin/ttyd"*) ok "清单含 ttyd" ;;
    *) bad "清单含 ttyd" "目标列表: $TARGETS" ;;
esac
case "$TARGETS" in
    *"server-start-robust.sh"*) ok "清单含部署脚本" ;;
    *) bad "清单含部署脚本" "缺失" ;;
esac

# ---------------------------------------------------------------
section "4. 部署脚本集成"
# ---------------------------------------------------------------
# 部署脚本必须能加载公共库
if grep -q 'lib/common.sh' "$ROOT/server-start-robust.sh"; then
    ok "部署脚本引用公共库"
else
    bad "部署脚本引用公共库" "未找到 lib/common.sh 引用"
fi

# 不允许再出现硬编码版本号
if grep -qE 'TTYD_VERSION="\$\{ENV_TTYD_VERSION:-\$\{DEPLOY_TTYD_VERSION:-1\.' "$ROOT/server-start-robust.sh"; then
    bad "无硬编码 ttyd 版本" "仍存在硬编码版本"
else
    ok "无硬编码 ttyd 版本"
fi

# make-bundle 版本号来自公共库
if grep -q 'VERSION="\$CRT_VERSION"' "$ROOT/make-bundle.sh"; then
    ok "打包版本号单一来源"
else
    bad "打包版本号单一来源" "make-bundle.sh 未使用 \$CRT_VERSION"
fi

# 打包脚本必须包含 lib/common.sh
if grep -q 'lib/common.sh' "$ROOT/make-bundle.sh"; then
    ok "打包包含公共库"
else
    bad "打包包含公共库" "make-bundle.sh 未复制 lib/common.sh"
fi

# 部署脚本必须把 ttyd 绑定到回环地址 (安全要求)
if grep -q -- '-i 127.0.0.1' "$ROOT/server-start-robust.sh" && \
   grep -q -- '-i 127.0.0.1' "$ROOT/tunnel-daemon.sh"; then
    ok "ttyd 仅监听回环"
else
    bad "ttyd 仅监听回环" "存在非回环绑定"
fi

# ---------------------------------------------------------------
section "5. 连接器参数解析"
# ---------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
    PARSED="$(cd "$ROOT" && python3 -c "
import sys
sys.argv = ['connect.py', 'myserver', '--upload', './a.txt', '/tmp/b.txt']
import connect
opts, rest = connect.parse_args()
print(opts['upload'], connect._target_after(sys.argv[1:], '--upload'))
" 2>/dev/null)"
    assert_eq "上传参数解析" "./a.txt /tmp/b.txt" "$PARSED"

    PARSED2="$(cd "$ROOT" && python3 -c "
import sys
sys.argv = ['connect.py', 'myserver', '--download', '/var/log/x.log']
import connect
opts, rest = connect.parse_args()
print(opts['download'], connect._target_after(sys.argv[1:], '--download'))
" 2>/dev/null)"
    assert_eq "下载参数解析" "/var/log/x.log None" "$PARSED2"

    PARSED3="$(cd "$ROOT" && python3 -c "
import sys
sys.argv = ['connect.py', '--chunk', '4096', 'myserver', 'echo hi']
import connect
opts, rest = connect.parse_args()
print(opts['chunk'], rest)
" 2>/dev/null)"
    assert_eq "分块参数解析" "4096 ['myserver', 'echo hi']" "$PARSED3"

    # shell 转义必须安全
    QUOTED="$(cd "$ROOT" && python3 -c "
import sys
sys.argv = ['connect.py']
import connect
print(connect._shq(\"a'b\"))
" 2>/dev/null)"
    assert_eq "shell 单引号转义" "'a'\\''b'" "$QUOTED"

    # 体积护栏必须存在且上下传都有
    GUARD="$(cd "$ROOT" && python3 -c "
import sys
sys.argv = ['connect.py']
import connect
print(connect.SMALL_FILE_LIMIT)
" 2>/dev/null)"
    assert_eq "体积上限已定义" "4194304" "$GUARD"
    if grep -q 'SMALL_FILE_LIMIT' "$ROOT/connect.py" && \
       [ "$(grep -c 'SMALL_FILE_LIMIT' "$ROOT/connect.py")" -ge 3 ]; then
        ok "上传与下载均有体积护栏"
    else
        bad "上传与下载均有体积护栏" "护栏引用次数不足"
    fi

    # 关闭回显是传输可靠性的关键, 且必须在 finally 中恢复
    if grep -q '_echo_off(s)' "$ROOT/connect.py"; then ok "传输前关闭回显"; else bad "传输前关闭回显" "未找到"; fi
    if grep -q '_echo_on(s)' "$ROOT/connect.py" && \
       [ "$(grep -c '_echo_on(s)' "$ROOT/connect.py")" -ge 2 ]; then
        ok "会话结束恢复回显"
    else
        bad "会话结束恢复回显" "finally 中未调用 _echo_on"
    fi

    # base64 提取必须能处理"提示符+数据"粘连
    EXTRACT="$(cd "$ROOT" && python3 -c "
import sys
sys.argv = ['connect.py']
import connect
raw = b'bash-3.2\$ QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo=\r\nCRT_DL_END_0\r\n'
print(connect._extract_b64(raw, b'CRT_DL_END_0'))
" 2>/dev/null)"
    assert_eq "base64 提取跳过提示符" "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo=" "$EXTRACT"

    # 半帧超时不能污染后续帧: recv_exact 必须支持整体超时
    if grep -q 'def recv_exact(s, n, timeout=None)' "$ROOT/connect.py"; then
        ok "recv_exact 支持整体超时"
    else
        bad "recv_exact 支持整体超时" "签名未更新, 半帧会导致流错位"
    fi

    # 无重复函数定义 (改代码时容易误复制)
    for fn in _echo_off _echo_on _read_until _extract_b64 run_upload run_download; do
        cnt="$(grep -c "^def $fn" "$ROOT/connect.py")"
        if [ "$cnt" = "1" ]; then ok "函数定义唯一 $fn"; else bad "函数定义唯一 $fn" "定义了 $cnt 次"; fi
    done
fi

# ---------------------------------------------------------------
section "6. 文档与配置一致性"
# ---------------------------------------------------------------
for f in README.md README-BUNDLE.md deploy.conf.example cloudflared-config.yml \
         connect.json.example tunnel-credentials.json.example LICENSE; do
    if [ -s "$ROOT/$f" ]; then ok "存在 $f"; else bad "存在 $f" "文件缺失或为空"; fi
done

# verify.sh 必须存在且被文档提到
if [ -s "$ROOT/verify.sh" ]; then ok "存在 verify.sh"; else bad "存在 verify.sh" "缺失"; fi
if grep -q 'verify.sh' "$ROOT/README-BUNDLE.md"; then ok "README 提到 verify.sh"; else bad "README 提到 verify.sh" "未提及"; fi
if grep -q 'verify.sh' "$ROOT/make-bundle.sh"; then ok "打包包含 verify.sh"; else bad "打包包含 verify.sh" "未包含"; fi

# 守护进程必须做完整性巡检
if grep -q 'crt_manifest_verify' "$ROOT/tunnel-daemon.sh"; then
    ok "守护进程巡检完整性"
else
    bad "守护进程巡检完整性" "未调用 crt_manifest_verify"
fi

# 卸载必须先解锁 (否则 chattr +i 的文件删不掉)
if grep -q 'chattr -i' "$ROOT/uninstall.sh"; then ok "卸载前解锁"; else bad "卸载前解锁" "未处理 chattr 锁"; fi

# README 中的命令应真实存在
for cmd in setup-tunnel.sh server-start-robust.sh make-bundle.sh install.sh uninstall.sh verify.sh connect.sh; do
    if [ -x "$ROOT/$cmd" ] || [ -f "$ROOT/$cmd" ]; then ok "脚本存在 $cmd"; else bad "脚本存在 $cmd" "README 提到但文件不存在"; fi
done

# .gitignore 必须忽略凭证与产物
for pat in deploy.conf tunnel-credentials.json connect.json dist/; do
    if grep -qF "$pat" "$ROOT/.gitignore"; then ok ".gitignore 忽略 $pat"; else bad ".gitignore 忽略 $pat" "未找到"; fi
done

# ---------------------------------------------------------------
section "7. 打包冒烟 (不联网)"
# ---------------------------------------------------------------
# 只验证打包脚本的静态逻辑, 不实际下载二进制
if bash -n "$ROOT/make-bundle.sh" 2>/dev/null; then ok "打包脚本可解析"; else bad "打包脚本可解析" "语法错误"; fi

# 打包脚本必须校验源文件完整性
if grep -q 'SHA256SUMS' "$ROOT/make-bundle.sh"; then ok "打包生成校验清单"; else bad "打包生成校验清单" "未找到"; fi
if grep -q 'SHA256SUMS' "$ROOT/install.sh"; then ok "安装校验清单"; else bad "安装校验清单" "未找到"; fi

# 默认不得夹带凭证
if grep -q 'ALLOW_SECRETS' "$ROOT/make-bundle.sh"; then ok "凭证默认剔除逻辑存在"; else bad "凭证默认剔除逻辑存在" "未找到"; fi

# 空清单不得误报"校验通过" (install.sh 必须用 -s 而非 -f 判断清单非空)
TMPI="$TMPD/instest"
mkdir -p "$TMPI/bin" "$TMPI/lib" "$TMPI/home"
cp "$ROOT/install.sh" "$TMPI/"
cp "$ROOT/lib/common.sh" "$TMPI/lib/"
make_fake_elf "$TMPI/bin/ttyd"
make_fake_elf "$TMPI/bin/cloudflared"
printf '#!/bin/bash\ntrue\n' > "$TMPI/server-start-robust.sh"
printf 'linux-%s\n' "$(crt_detect_arch)" > "$TMPI/.arch"
: > "$TMPI/SHA256SUMS"
INST_OUT="$(cd "$TMPI" && HOME="$TMPI/home" bash install.sh 2>&1)"
case "$INST_OUT" in
    *"跳过完整性校验"*) ok "空清单: 提示跳过而非误报" ;;
    *) bad "空清单: 提示跳过而非误报" "输出: $(printf '%s' "$INST_OUT" | head -3)" ;;
esac
case "$INST_OUT" in
    *"完整性校验通过"*) bad "空清单: 不误报通过" "空清单不应显示通过" ;;
    *) ok "空清单: 不误报通过" ;;
esac
case "$INST_OUT" in
    *"已生成完整性清单"*) ok "install.sh 生成部署清单" ;;
    *) bad "install.sh 生成部署清单" "未生成" ;;
esac

# ---- 二进制格式校验 (镜像错误页 / 半截下载 不得被当成可执行文件) ----
VB="$TMPD/validate"
mkdir -p "$VB"
make_fake_elf "$VB/good" 600000
printf '<html><body>502 Bad Gateway</body></html>\n' > "$VB/html"
head -c 1000 /dev/zero > "$VB/tiny"                       # 有 ELF 无 magic 都不算
printf '\177ELF' > "$VB/truncated"
printf 'not an elf but big enough padding to pass size check...' > "$VB/text"
head -c 600000 /dev/zero >> "$VB/text"

# 逐条验证 crt_validate_binary 的判定
vlib() { ( . "$ROOT/lib/common.sh"; crt_validate_binary "$@" ); }

assert_ok   "校验: 正常 ELF 通过"      vlib "$VB/good"
assert_fail "校验: HTML 错误页拒绝"    vlib "$VB/html"
assert_fail "校验: 4 字节半截文件拒绝" vlib "$VB/truncated"
assert_fail "校验: 大文本文件拒绝"     vlib "$VB/text"
assert_fail "校验: 不存在的文件拒绝"   vlib "$VB/nope"

# 体积下限必须真的生效: 同一内容低于下限要被拒
assert_fail "校验: 低于体积下限拒绝"   vlib "$VB/good" 1000000

# 打包脚本必须走"下载即校验"的入口, 不能直接用裸下载函数
if grep -q 'fetch_binary' "$ROOT/make-bundle.sh" && \
   ! grep -qE 'fetch_with_mirror "\$stage/bin' "$ROOT/make-bundle.sh"; then
    ok "打包: 下载后校验 ELF"
else
    bad "打包: 下载后校验 ELF" "仍在使用未校验的下载入口"
fi
if grep -q 'fetch_binary' "$ROOT/make-bundle.sh"; then ok "打包脚本定义校验下载"; else bad "打包脚本定义校验下载" "未找到"; fi

# 部署脚本: 下载与"已存在"两条路径都必须校验
if grep -q 'download_binary' "$ROOT/server-start-robust.sh"; then ok "部署: 下载后校验 ELF"; else bad "部署: 下载后校验 ELF" "未找到"; fi
if grep -q 'crt_validate_binary "\$TTYD_BIN"' "$ROOT/server-start-robust.sh" && \
   grep -q 'crt_validate_binary "\$CF_BIN"' "$ROOT/server-start-robust.sh"; then
    ok "部署: 已存在二进制也校验"
else
    bad "部署: 已存在二进制也校验" "已存在路径未校验"
fi

# 安装脚本: 包内二进制必须校验
if grep -q 'crt_validate_binary' "$ROOT/install.sh"; then ok "安装: 校验包内二进制"; else bad "安装: 校验包内二进制" "未找到"; fi

# 反面用例: 把 HTML 错误页当二进制, install.sh 必须拒绝安装
TMPI2="$TMPD/instest2"
mkdir -p "$TMPI2/bin" "$TMPI2/lib" "$TMPI2/home"
cp "$ROOT/install.sh" "$TMPI2/"
cp "$ROOT/lib/common.sh" "$TMPI2/lib/"
printf '<html><body>404 Not Found from mirror</body></html>\n' > "$TMPI2/bin/ttyd"
make_fake_elf "$TMPI2/bin/cloudflared"
printf 'linux-%s\n' "$(crt_detect_arch)" > "$TMPI2/.arch"
: > "$TMPI2/SHA256SUMS"
INST2_OUT="$(cd "$TMPI2" && HOME="$TMPI2/home" bash install.sh 2>&1)"
case "$INST2_OUT" in
    *"不是有效的 Linux 可执行文件"*) ok "安装: 拒绝 HTML 错误页" ;;
    *) bad "安装: 拒绝 HTML 错误页" "输出: $(printf '%s' "$INST2_OUT" | head -3)" ;;
esac
if [ -f "$TMPI2/home/.local/bin/ttyd" ]; then
    bad "安装: 拒绝后未安装" "坏文件仍被装到 bin"
else
    ok "安装: 拒绝后未安装"
fi

# ---------------------------------------------------------------
section "8. 自启动 (autostart / resume)"
# ---------------------------------------------------------------
# 沙箱 HOME + CRT_NO_CRON=1 (绝不触碰真实 crontab)
AST="$TMPD/autostart"
mkdir -p "$AST/home" "$AST/pkg/lib"
cp "$ROOT/autostart.sh" "$ROOT/resume.sh" "$ROOT/tunnel-daemon.sh" "$AST/pkg/"
cp "$ROOT/lib/common.sh" "$AST/pkg/lib/"

assert_ok "autostart status 可运行" env HOME="$AST/home" CRT_NO_CRON=1 bash "$AST/pkg/autostart.sh" status

env HOME="$AST/home" CRT_NO_CRON=1 bash "$AST/pkg/autostart.sh" enable >/dev/null 2>&1
if grep -q "cloud-remote-tunnel autostart" "$AST/home/.profile" 2>/dev/null; then
    ok "enable 写入登录钩子"
else
    bad "enable 写入登录钩子" ".profile 中未找到标记"
fi
if [ -f "$AST/home/.cloud-remote-tunnel/app/resume.sh" ] && [ -f "$AST/home/.cloud-remote-tunnel/app/tunnel-daemon.sh" ]; then
    ok "enable 复制运行时副本到 app 目录"
else
    bad "enable 复制运行时副本到 app 目录" "app 目录内容不全"
fi

# 幂等: 标记块不得重复
env HOME="$AST/home" CRT_NO_CRON=1 bash "$AST/pkg/autostart.sh" enable >/dev/null 2>&1
CNT="$(grep -c "^# >>> cloud-remote-tunnel autostart >>>" "$AST/home/.profile" 2>/dev/null || true)"
assert_eq "enable 幂等 (标记块唯一)" "1" "${CNT:-0}"

# disable: 清理钩子但保留程序
env HOME="$AST/home" CRT_NO_CRON=1 bash "$AST/pkg/autostart.sh" disable >/dev/null 2>&1
CNT="$(grep -c "cloud-remote-tunnel autostart" "$AST/home/.profile" 2>/dev/null || true)"
assert_eq "disable 移除登录钩子" "0" "${CNT:-0}"
if [ -f "$AST/home/.cloud-remote-tunnel/app/resume.sh" ]; then
    ok "disable 保留运行时副本"
else
    bad "disable 保留运行时副本" "app 目录被误删"
fi

# resume: 无部署时静默退出
env HOME="$AST/empty" bash "$ROOT/resume.sh" >/dev/null 2>&1
assert_eq "resume 未部署时静默退出(0)" "0" "$?"

# 部署脚本集成的静态断言
if grep -q 'autostart.sh' "$ROOT/server-start-robust.sh"; then ok "部署脚本调用 autostart"; else bad "部署脚本调用 autostart" "未找到调用"; fi
if grep -q 'AUTOSTART' "$ROOT/server-start-robust.sh"; then ok "部署脚本支持 AUTOSTART 开关"; else bad "部署脚本支持 AUTOSTART 开关" "未找到"; fi
if grep -q 'autostart.sh' "$ROOT/uninstall.sh"; then ok "卸载脚本清理自启动"; else bad "卸载脚本清理自启动" "未找到"; fi
if grep -q 'autostart.sh' "$ROOT/make-bundle.sh" && grep -q 'resume.sh' "$ROOT/make-bundle.sh"; then
    ok "打包包含自启动脚本"
else
    bad "打包包含自启动脚本" "make-bundle.sh 缺文件"
fi
if grep -q 'autostart.sh' "$ROOT/lib/common.sh"; then ok "清单覆盖自启动脚本"; else bad "清单覆盖自启动脚本" "未找到"; fi

# ---------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------
TOTAL=$((PASS + FAIL))
printf '\n\033[1m==============================================\033[0m\n'
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32m  ✅ 全部通过: %d/%d\033[0m\n' "$PASS" "$TOTAL"
    printf '\033[1m==============================================\033[0m\n'
    exit 0
else
    printf '\033[31m  ❌ 失败 %d 项 / 共 %d 项\033[0m\n' "$FAIL" "$TOTAL"
    printf '  失败列表:%s\n' "$FAILED_NAMES"
    printf '\033[1m==============================================\033[0m\n'
    exit 1
fi
