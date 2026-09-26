#!/bin/sh
# MClaw 远程终端连接器入口 — 用法见 connect.py 文件头
# ./connect.sh 服务器名           交互式终端
# ./connect.sh 服务器名 "命令"    执行单条命令
exec python3 "$(dirname "$0")/connect.py" "$@"
