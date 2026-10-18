#!/bin/sh
# Cloud Remote Tunnel 连接器入口 — 详细用法见 connect.py 文件头 或 ./connect.sh --help
#
# 常用:
#   ./connect.sh 服务器名               交互式终端
#   ./connect.sh 服务器名 "命令"         执行单条命令(退出码透传)
#   ./connect.sh --check                连通性自检
#   ./connect.sh --list                 列出已登记服务器
#   TUNNEL_URL=... TUNNEL_USER=... TUNNEL_PASSWORD=... ./connect.sh "命令"   环境变量免密模式
if ! command -v python3 >/dev/null 2>&1; then
    echo "需要 python3 (macOS/Linux 自带)" >&2
    exit 2
fi
exec python3 "$(dirname "$0")/connect.py" "$@"
