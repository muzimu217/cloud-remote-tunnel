# Cloud Remote Tunnel · 云端容器远程终端配置包

> 前身 `mclaw-remote-tunnel`：最初为**中国移动 MClaw（小龙虾）**定制的内网穿透配置包，现已泛化为任意 **Linux 云服务器 / 云端容器**通用的远程终端方案。

把隔离的云端环境通过 **Cloudflare Tunnel** 挂到你自己的域名上；本地 `./connect.sh` 一条命令直连远程终端——像 SSH 一样，给云端跑的 AI agent / coding 工具留一个摸得着的口子。

**v3.1 新特性**：架构自适应 (amd64/arm64/armv7/386) · 零硬编码凭证（自动生成随机密码）· 三种隧道模式自动选择 · 一键部署输出"连接卡片" · 环境变量免密模式（AI / CI 友好）· `setup-tunnel.sh` 域名接入自动化 · **文件上传/下载** · **71 项自动化测试 + CI**。

---

## 核心功能

- ✅ **一键部署** - `bash server-start-robust.sh` 自动完成全部配置并输出连接卡片
- ✅ **架构自适应** - 自动检测 x86_64 / arm64 / armv7 / 386 并下载对应二进制
- ✅ **零硬编码凭证** - 终端密码自动生成（也可环境变量注入），不再需要手改脚本
- ✅ **三种隧道模式** - 命名隧道（专属域名）/ Token（控制台托管）/ 临时隧道（免账号测试）
- ✅ **进程守护** - 每 10 秒巡检，ttyd / cloudflared 挂掉自动拉起；容器重启后可快速恢复
- ✅ **自启动** - 默认装好两条独立通道（crontab `@reboot` + 登录钩子），无 systemd 的容器重启后自动恢复，可一条命令关闭
- ✅ **本地一键连接** - 纯 Python 标准库实现的直连客户端，无需浏览器
- ✅ **文件传输** - `--upload` / `--download` 复用终端会话，远端无需 sshd 或额外端口
- ✅ **AI / 脚本免密调用** - 环境变量注入凭证，`--check` 自检、`--json` 结构化输出、退出码透传
- ✅ **域名接入自动化** - `setup-tunnel.sh` 一键完成建隧道 + 绑域名 + 生成部署包
- ✅ **国内加速** - 二进制下载支持 gh-proxy 镜像，且自动回退 GitHub 直连
- ✅ **离线部署包** - 本机打包 → 服务器解压即启动（无需联网，含完整性校验与干净卸载）
- ✅ **防误改** - 部署清单 + `verify.sh` 校验 + 可选只读锁定 + 守护进程自动巡检
- ✅ **可验证** - `tests/run-tests.sh` 116 项测试，GitHub Actions 自动跑 shellcheck + 测试 + 打包冒烟

---

## 快速开始（3 步）

### 第 1 步 · 本地接入域名（有专属域名时）

在**本地电脑**上运行（需要浏览器登录一次 Cloudflare）：

```bash
./setup-tunnel.sh tunnel.example.com
```

脚本会自动：登录 Cloudflare → 创建隧道（已存在则复用）→ 绑定域名 DNS → 生成 `tunnel-credentials.json` + `deploy.conf`。

> 没有域名？跳过此步，服务端会用**临时隧道模式**（trycloudflare.com 随机地址，仅供测试）。

### 第 2 步 · 部署到云容器

把本目录（或整个压缩包）上传到云容器任意目录，然后：

```bash
cd remote
bash server-start-robust.sh
```

脚本自动：检测架构 → 下载 ttyd/cloudflared（国内镜像）→ 生成随机密码 → 启动隧道 + 终端 + 守护进程 → 输出**连接卡片**：

```
==============================================
  📋 连接卡片 (Connection Card)
==============================================
  模式    : config
  地址    : https://tunnel.example.com/terminal/
  用户名  : openclaw
  密码    : <自动生成的随机密码>
----------------------------------------------
  自检: 本地终端 ✓ | 隧道 ✓
----------------------------------------------
  本地免密连接 (在本地电脑执行):
  [A] 登记到 connect.json (推荐):
      TUNNEL_URL='https://tunnel.example.com' TUNNEL_USER='openclaw' TUNNEL_PASSWORD='...' \
        ./connect.sh --add-server myserver
  [B] 环境变量直连:
      TUNNEL_URL='...' TUNNEL_USER='...' TUNNEL_PASSWORD='...' ./connect.sh "命令"
==============================================
```

### 第 3 步 · 本地连接

```bash
TUNNEL_URL='https://tunnel.example.com' TUNNEL_USER='openclaw' TUNNEL_PASSWORD='...' \
  ./connect.sh --add-server myserver     # 登记一次（写入 connect.json，之后直接按名称连接）

./connect.sh myserver                     # 交互式终端（Ctrl-] 退出，其余按键全部透传）
./connect.sh myserver "uptime"            # 执行单条命令，输出后退出（退出码透传）
```

> 💡 网络受限的环境（如国内直连 Cloudflare 不稳）会在直连失败后自动尝试本机 `127.0.0.1:7897` HTTP 代理兜底（可用 `CRT_PROXY_FALLBACK` 环境变量修改，置空禁用）。

---

## 文件传输

目标容器里没有 sshd、也不方便开额外端口时，用同一条终端会话传文件：

```bash
./connect.sh myserver --upload ./build.tar.gz                  # 传到远端家目录
./connect.sh myserver --upload ./build.tar.gz /opt/app/        # 指定远端目录
./connect.sh myserver --download /var/log/app.log              # 下载到本地同名文件
./connect.sh myserver --download /var/log/app.log ./app.log    # 指定本地路径
```

- **零依赖**：远端不需要 `sshd` / `scp` / `rsync`，只要有 `base64` 和 `tail`（几乎所有 Linux 都有）；
- **可靠**：传输前关闭终端回显避免标记歧义，分块确认 + 大小校验，失败即中止（下载先写 `.part` 再改名）；
- **`--json`**：返回 `{"ok":true,"action":"upload","bytes":...,"seconds":...}`，便于 AI 判断。

### 实测性能与边界

在 Cloudflare quick tunnel 上实测（本地 → 隧道 → 服务端）：

| 文件大小 | 结果 | 耗时 | 校验 |
|---|---|---|---|
| 200 KB | ✅ 成功 | 24.5s | SHA256 一致 |
| 2 MB | ✅ 成功 | 186s | SHA256 一致 |
| 5 MB | ⚠️ 不稳定 | — | 中途超时 |

**吞吐约 11 KB/s**，主要成本是每次往返 ~0.5s。这是 ttyd 协议的固有边界——它设计给交互式终端，不是文件传输协议。

**因此：4MB 以内可直接用**（默认护栏，实测 2MB 稳定、5MB 不稳），超过会提示改用专用通道：

```bash
# 大文件推荐 croc：两端各一个 9MB 单文件，P2P 优先，不需要域名
croc send bigfile.zip          # 一端
croc 2450-fiesta-video-joshua  # 另一端
```

`--force` 可强制尝试超过建议上限的文件。

> **关于 CF 的 100MB 限制**：实测确认它作用于 **HTTP 请求体**（101MB POST 返回 `413 Payload Too Large`，99MB 正常）。我们的传输走 **WebSocket 流**，单帧发到 16MB 也不触发该限制——所以限制点不是 100MB，而是终端通道本身的吞吐和稳定性。换句话说：CF 不限你传多大，但终端通道传不快。

---

## 离线部署包（解压即启动，服务器无需联网）

服务器连不上 GitHub、或想固定一套版本部署时，在本机打包后上传：

```bash
./make-bundle.sh --arch amd64        # 或 --all 同时打 amd64 + arm64
# 产物: dist/crt-bundle-3.0.0-linux-amd64.tar.gz (+ .sha256 校验文件)
```

上传服务器后，一条命令完成部署（校验 → 安装 → 自动启动 → 输出连接卡片）：

```bash
tar xzf crt-bundle-3.0.0-linux-amd64.tar.gz
cd crt-bundle-3.0.0-linux-amd64
bash install.sh
```

- **无需联网**：ttyd / cloudflared 二进制已内置于包中；
- **默认装好自启动**：`@reboot` + 登录钩子两条通道（`--no-autostart` / `AUTOSTART=no` 可跳过）；
- **完整性校验**：含 SHA256SUMS，文件被改动会被拒绝安装；
- **默认不夹带凭证**：如用 `--config` 带入配置，密码 / Token 字段会被自动剔除（`--allow-secrets` 可显式保留，仅限自用）；
- **防误改**：安装后生成部署清单，`bash verify.sh` 随时校验；`--lock` 可设只读（守护进程每 10 分钟自动巡检一次）；
- **干净可审计**：全部脚本明文可读（不做混淆），只写用户目录、不改系统文件；
- **可退出**：`bash uninstall.sh [--purge]` 一键干净卸载（含解锁处理）。

---

## AI / 自动化免密调用（重点）

给 AI agent、CI、脚本调用做了完整设计——**全程无交互、无密码提示**，凭据通过环境变量注入：

```bash
# 免密直连（无需 connect.json）：
export TUNNEL_URL="https://tunnel.example.com"
export TUNNEL_USER="openclaw"
export TUNNEL_PASSWORD="<部署卡片里的密码>"

./connect.sh "systemctl status nginx"       # 执行命令，退出码透传
./connect.sh --json "make build"            # JSON 输出: {"ok":..., "exit_code":..., "output":...}
./connect.sh --check                        # 连通性自检 (token 获取 + WebSocket 握手)
```

- **退出码透传**：远端命令的退出码原样返回（超时 124，连接失败 1，用法错误 2），AI 可直接判断成败；
- **`--json`**：结构化输出，便于程序解析；
- **`--check`**：调用前快速验证链路（token + 握手 + 回显），失败时给出明确原因；
- **凭证不落地**：环境变量方式不会写任何文件；`--add-server` 登记的文件权限为 600 且已被 `.gitignore` 忽略。

---

## 三种隧道模式

| 模式 | 适用场景 | 地址 | 准备 |
|------|---------|------|------|
| `config`（推荐） | 有专属域名，长期使用 | `https://你的域名/terminal/` | `setup-tunnel.sh` 生成凭证 |
| `token` | 偏爱在 Cloudflare 控制台管理路由 | 控制台配置的域名 | 控制台创建隧道拿 Token |
| `quick` | 无账号快速测试 | `https://随机.trycloudflare.com` | 无（地址会变化） |

模式由 `deploy.conf` / 环境变量的 `TUNNEL_MODE` 控制（默认 `auto` 自动选择）。

---

## 配置参考

### 服务端 `deploy.conf`（复制 `deploy.conf.example`）

| 变量 | 说明 | 默认 |
|------|------|------|
| `TTYD_USER` | 终端用户名 | `openclaw` |
| `TTYD_PASS` | 终端密码（留空自动生成） | 随机 |
| `TTYD_PORT` | 终端端口 | `7681` |
| `TUNNEL_MODE` | `auto` / `config` / `token` / `quick` | `auto` |
| `TUNNEL_DOMAIN` | 专属域名（config 模式必填） | — |
| `TUNNEL_TOKEN` | 隧道 Token（token 模式使用） | — |
| `GH_MIRROR` | 二进制下载镜像 | `https://gh-proxy.com` |

以上均可直接用**环境变量**传入（优先级高于 `deploy.conf`），适合 CI / AI 自动化：

```bash
TTYD_PASS="强密码" TUNNEL_DOMAIN="tunnel.example.com" bash server-start-robust.sh
```

### 本地 `connect.json`（复制 `connect.json.example`）

```json
{
  "default": "myserver",
  "proxy": "",
  "proxy_fallback": "http://127.0.0.1:7897",
  "servers": {
    "myserver": { "url": "https://tunnel.example.com", "user": "openclaw", "password": "..." }
  }
}
```

### 本地环境变量（免密模式）

| 变量 | 说明 |
|------|------|
| `TUNNEL_URL` / `TUNNEL_USER` / `TUNNEL_PASSWORD` | 免密直连凭据 |
| `TUNNEL_PROXY` | 代理地址（等价 `--proxy`） |
| `CRT_PROXY_FALLBACK` | 兜底代理（默认 `http://127.0.0.1:7897`） |
| `CRT_CONFIG` | connect.json 路径 |
| `CRT_DEBUG` | 调试日志（`/tmp/crt_debug.log`） |

### 服务端文件布局（部署后）

```
~/.local/bin/ttyd              # Web 终端
~/.local/bin/cloudflared       # 隧道
~/.cloud-remote-tunnel/        # 凭证 (600): credentials.env / quick-url.txt
~/.cloudflared/config.yml      # 隧道配置（config 模式）
~/connection-card.txt          # 连接卡片 (600)
~/.local/log/                  # ttyd.log / cloudflared.log / tunnel-daemon.log
```

---

## 项目结构与开发

```
cloud-remote-tunnel/
├── lib/common.sh            # 公共库: 版本号/架构映射/URL校验/哈希/清单 (单一来源)
├── server-start-robust.sh   # 服务端一键部署
├── tunnel-daemon.sh         # 进程守护 + 完整性巡检
├── autostart.sh             # 服务端: 自启动管理 (登录钩子 / @reboot)
├── resume.sh                # 服务端: 幂等恢复入口
├── setup-tunnel.sh          # 本地: 建隧道 + 绑域名
├── make-bundle.sh           # 本地: 打离线包
├── install.sh               # 服务端: 解压即装
├── verify.sh                # 服务端: 完整性校验 / 只读锁定
├── uninstall.sh             # 服务端: 干净卸载
├── connect.py / connect.sh  # 本地连接器 (终端 / 命令 / 文件传输)
├── tests/run-tests.sh       # 116 项本地测试
└── .github/workflows/ci.yml # CI: shellcheck + 测试 + 打包冒烟
```

改动后跑一遍测试（无需网络、无需服务器）：

```bash
bash tests/run-tests.sh            # 全部用例
bash tests/run-tests.sh --verbose  # 逐项显示
```

升级二进制版本只需改 `lib/common.sh` 里的 `CRT_TTYD_VERSION_DEFAULT` / `CRT_CF_VERSION_DEFAULT`，部署与打包脚本会自动跟随。

---

## 网络环境要求：只需要能出站

这是本方案最关键的性质——**不需要公网 IP、不需要开放任何入站端口、不需要路由器端口映射**：

```
目标机器（NAT 后 / 隔离内网） --出站 443--> Cloudflare 边缘 <--浏览器/CLI-- 你
```

- `cloudflared` 主动**向外**连接 Cloudflare 边缘并保持长连接，你的访问请求由 CF 沿这条已有连接反向送进来；
- 所以**完全隔离的内网也可以访问**：只要目标容器能访问外网 443（哪怕出网经过公司代理、平台网关、NAT），隧道就能建立；
- 极端受限环境（只放行特定域名白名单）也能用：把 `*.cloudflare.com` / `*.argotunnel.com` / 你的域名加入白名单即可；
- **不能**用的只有一种情况：目标机器**完全没有任何出网能力**（连 443 都不通）。这种情况任何隧道方案都无解——包括 SSH 反向、frp、ngrok。

> 唯一无法绕过的是"有出网但只允许 HTTP 代理"的场景：此时给 `cloudflared` 配 `HTTPS_PROXY` 环境变量即可（默认安装脚本会探测常见本地代理端口）。

---

## 相关项目

本项目专注**单向访问与控制**：你 → 目标机器，走 Cloudflare Tunnel，只需要出站 443。

配套的**双向对等组网**项目是 [container-mesh](../container-mesh)（机器 ↔ 机器，双向消息、大文件传输、断点续传、纯用户态无 TUN），与本项目定位互补：

| | 本项目（cloud-remote-tunnel） | container-mesh |
|---|---|---|
| 方向 | 单向：人 → 机器 | 双向对等：A ↔ B |
| 传输 | 终端命令 + 中小文件 | 双向消息 + 大文件、断点续传 |
| 依赖 | 域名 + Cloudflare 账号 | 一个双方可达的中继（可自建） |
| 权限要求 | 只需出站 443 | 只需出站（纯用户态，无需 TUN / root） |
| 适合 | 远程运维、AI agent 接管、看日志 | 多机互联、批量同步、双向 RPC |

> 两个项目可以并存：本项目负责"随时能进去看一眼、敲一条命令"，container-mesh 负责"两台机器互相说话、搬大文件"。

---

## 常见问题

### Q: 部署后连不上？

1. 服务端看日志：`tail -30 ~/.local/log/cloudflared.log`；
2. 本地跑自检：`./connect.sh --check https://你的域名 用户名 密码`；
3. 国内网络受限时确认兜底代理可用（默认探测 `127.0.0.1:7897`）。

### Q: 容器重启后服务没恢复？

部署时**已默认装好自启动**，正常情况下不用管。自启动有两条独立通道，任一生效即可：

| 通道 | 触发 | 说明 |
|------|------|------|
| crontab `@reboot` | 容器/机器重启 | 无 systemd 也能用 |
| 登录钩子 (`~/.profile` 标记块) | 每次 SSH 登录 | 幂等，只写一块 |

两者都调用幂等入口 `resume.sh`（在跑就直接退出，不会重复起进程）：

```bash
bash autostart.sh status    # 看通道状态
bash autostart.sh enable    # 手动启用 (部署时已自动执行)
bash autostart.sh disable   # 关闭并清理条目
bash autostart.sh print-cmd # 输出可粘进容器平台"启动命令"的单行命令
```

若两条通道都被清理，手动恢复也很简单（凭证已存 `~/.cloud-remote-tunnel/`，**密码不会变**）：

```bash
bash ~/.cloud-remote-tunnel/app/resume.sh   # 平时用这条，幂等
bash install.sh                             # 或重跑完整安装（install.sh --no-autostart 可不装自启动）
```

### Q: 密码在哪里看？

- 部署时输出的连接卡片；
- 或服务端 `cat ~/connection-card.txt`（600 权限）；
- 或 `cat ~/.cloud-remote-tunnel/credentials.env`。

### Q: 换域名 / 换隧道？

重新跑 `./setup-tunnel.sh 新域名`，然后重新部署即可。

### Q: Tunnel Secret 找不到？

只显示一次。忘了就删除重建 Tunnel（`setup-tunnel.sh` 会自动处理），这次立即复制！

### Q: 我想保留原来的旧版工作流（openclaw-tunnel.json）？

仍然兼容：脚本会优先读取 `tunnel-credentials.json`，找不到时回退 `openclaw-tunnel.json`；旧版 `cloudflared-config.yml`（未替换占位符的）也会被原样复制使用。

---

## 附录：MClaw（小龙虾）备份还原玩法

<details>
<summary>点击展开（历史教程，MClaw 专用）</summary>

> ⚠️ **【注意事项】** 在进行以下任何操作之前，请务必先在中国移动 APP 的 **MClaw（小龙虾）** 界面中 **多做几次备份！多做几次备份！** 以防操作失误导致数据丢失或配置异常，备份是最可靠的恢复手段。

### 背景

MClaw 是 KVM 虚拟机（非容器），完全支持本方案的所有功能（含 TUN 相关实验）。通过 MClaw 的"备份还原"机制，可以把本配置包注入到云端环境并启动内网穿透。

### 操作步骤

1. **下载 MClaw 备份文件**：打开移动网盘 APP → 找到 `openclaw-xxx-时间戳.zip` → 下载到本地；
2. **解压备份**，把本仓库（`remote` 文件夹）放入解压后的根目录：

```
openclaw-xxx-时间戳/          ← 解压后的根目录
├── agents/
├── devices/
├── remote/                   ← 放这里！
├── workspace/
└── ...
```

3. **配置隧道**（如需内网穿透）：按本文档「快速开始」的 `setup-tunnel.sh` 流程生成 `tunnel-credentials.json` 和 `deploy.conf`，一并放入 `remote/`；
4. **重新打包**（⚠️ 包名必须和下载的完全一致）：

```bash
zip -r openclaw-1287296976021332797-20260603120000.zip openclaw-1287296976021332797-20260603120000/
```

5. **上传回原路径**（移动网盘相同位置），在 MClaw 管理界面点「还原系统」；
6. 还原后对 MClaw 内的 AI 发送指令：`进入 remote 目录，执行 bash server-start-robust.sh`。

### 云盘直下法（备份还原无效时）

1. 将本仓库 ZIP 上传到云盘空间（确保可通过链接访问）；
2. 让 MClaw AI 执行：`从云盘下载 remote 配置包（链接：…），解压到 remote 目录，执行 bash server-start-robust.sh`；
3. 等待部署完成，按输出的连接卡片连接。

### 模型替换（可选）

修改 `agents/main/agent/models.json` 中 `providers.router` 的字段（不要新建 provider）：

| 字段 | 示例 |
|------|------|
| `baseUrl` | `https://api.deepseek.com/v1` |
| `apiKey` | 你的 API Key |
| `models[0].id` / `name` | `deepseek-chat` |
| `reasoning` | 推理模型设 `true` |

支持：DeepSeek Chat/R1、MiMo、GPT-4o、本地 Ollama 等（OpenAI 兼容格式）。

</details>

---

## 致谢

感谢 [Linux.do](https://linux.do) 社区的支持与贡献：
- **JSW** — 信息资讯分享
- **Yumenosora** — 写给小白的 MClaw 轮椅♿️教程分享

---

## 社区交流

[![Linux Do](https://img.shields.io/badge/社区-Linux%20Do-f5a623)](https://linux.do)

本项目的发布、讨论与反馈在 [Linux Do 社区](https://linux.do)进行，欢迎来吹水、提需求、交换邪修玩法。Issue / PR 直接走 GitHub。

---

## 许可证

MIT License
