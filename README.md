# MClaw 内网穿透配置包

**中国移动 MClaw 备份文件** 内网穿透配置，放入备份文件即可实现远程访问。同时支持**模型替换**自定义 AI。

---

## 核心功能

- ✅ **内网穿透** - Cloudflare Tunnel 远程访问 OpenClaw
- ✅ **模型替换** - 通过备份还原方式替换内置模型

---

> ⚠️ **【注意事项】** 在进行以下任何操作之前，请务必先在中国移动 APP 的 **MClaw（小龙虾）** 界面中 **多做几次备份！多做几次备份！** 以防操作失误导致数据丢失或配置异常，备份是最可靠的恢复手段。

---

## 使用方法

### 步骤 1：下载此配置包

点击右上角 **「Code」** → **「Download ZIP」** 下载，或：

```bash
git clone https://github.com/muzimu217/mclaw-remote-tunnel.git
```

### 步骤 2：下载 MClaw 备份文件（重点！）

1. 打开 **移动网盘** APP 或网页版
2. 进入你存放 OpenClaw 备份的路径
3. 找到刚刚备份的系统 zip 文件（文件名类似 `openclaw-xxx-时间戳.zip`）
4. **下载到本地**

⚠️ **注意事项**：
- 记住这个 zip 文件的**完整文件名**（包括前缀和时间戳）
- 记住这个 zip 文件存放的**路径位置**
- 后面打包和上传时必须完全一致！

### 步骤 3：解压备份并放入配置包

1. 解压下载的 zip 文件
2. 将此配置包（`remote` 文件夹）放入解压后的根目录：

```
openclaw-xxx-时间戳/          ← 解压后的根目录
├── agents/
├── devices/
├── remote/                   ← 放这里！根目录
│   ├── openclaw-tunnel.json
│   ├── cloudflared-config.yml
│   ├── server-start-robust.sh
│   └── README.md
├── workspace/
└── ...
```

### 步骤 4：配置 Tunnel（如需内网穿透）

#### 4.1 登录 Cloudflare

访问：**https://dash.cloudflare.com/** → 登录账号

#### 4.2 创建 Tunnel

1. 点击 **「Zero Trust」** → **「Networks」** → **「Tunnels」**
2. 点击 **「Create a tunnel」**
3. 选择 **「Cloudflared」**
4. 输入名称如 `openclaw-tunnel`，保存

#### 4.3 获取配置信息

创建后记录以下信息：

| 字段 | 位置 | 格式 |
|------|------|------|
| Tunnel ID | 页面顶部 | UUID 格式 |
| Account Tag | 点击「View configuration details」 | 32位字符 |
| Tunnel Secret | 创建时显示 | 长字符串（只显示一次！） |

#### 4.4 填入配置文件

**openclaw-tunnel.json**：
```json
{
  "AccountTag": "你的AccountTag",
  "TunnelID": "你的TunnelID",
  "TunnelName": "openclaw-tunnel",
  "TunnelSecret": "你的TunnelSecret"
}
```

**cloudflared-config.yml**：
```yaml
tunnel: 你的TunnelID
ingress:
  - hostname: 你的域名.com
    path: /terminal*
    service: http://localhost:7681
  ...
```

### 步骤 5：打包上传还原（重点！）

⚠️ **注意事项（非常重要）**：

1. **zip 包名一定要和下载的那个备份文件名一模一样！**
   - 下载的是 `openclaw-1287296976021332797-20260603120000.zip`
   - 打包时必须用完全相同的名字！

2. **上传到和下载备份包一样的路径**
   - 直接替换原本的包
   - 路径不一致会导致还原失败！

打包命令示例：
```bash
# 确保包名和原下载文件完全一致（示例）
zip -r openclaw-1287296976021332797-20260603120000.zip openclaw-1287296976021332797-20260603120000/
```

不过我希望各位在此实践之前，前往ide.cloud.tencent.com，将备份包上传到自己的云虚拟容器，先进行测试验证，通过之后再上传中国移动的：全部>AI空间>MClaw空间>MClaw备份（备份包名字一定要一致！！！）

上传后在 MClaw 管理界面点击 **「还原系统」**。

### 步骤 6：备份还原后发送给 AI 的指令（重点！）

系统还原完成后，你需要给 AI 发送以下指令来启动内网穿透服务：

#### 发送给 AI 的指令：

```
进入 remote 目录，执行 server-start-robust.sh 启动内网穿透
```

或者更详细的指令：

```
请帮我启动内网穿透服务：
1. 先安装依赖：apt update && apt install -y wget curl procps
2. 进入 remote 目录
3. 执行 ./server-start-robust.sh
```

#### AI 会自动执行：

1. 检查并安装前置依赖（wget、curl、procps）
2. 下载 ttyd 和 cloudflared 二进制文件
3. 配置 Cloudflare Tunnel
4. 启动 Web 终端（端口 7681）
5. 启动 Tunnel 连接

#### 验证启动成功：

AI 启动后，你可以通过以下地址访问：

- **Web 终端**: `https://你的域名.com/terminal/`
- **Web 界面**: `https://你的域名.com/`

---

## 如果在云服务器上操作

如果你是在云服务器（如腾讯云 Cloud Studio）上操作，可以直接执行：

```bash
apt update && apt install -y wget curl procps
cd remote
./server-start-robust.sh
```

---

## 模型替换（可选）

想替换内置模型为 DeepSeek、MiMo、GPT 等，按以下步骤操作：

### 模型配置文件位置

```
agents/main/agent/models.json
```


### 替换方案

直接修改 `providers.router` 下的三个关键字段：

```json
{
  "providers": {
    "router": {
      "baseUrl": "https://api.deepseek.com/v1",    ← 改这里
      "apiKey": "你的API-Key",                      ← 改这里
      "api": "openai-completions",
      "models": [
        {
          "id": "deepseek-chat",                   ← 改这里
          "name": "deepseek-chat",                 ← 改这里
          "api": "openai-completions",
          "reasoning": false,                      ← 推理模型设为 true
          ...
        }
      ]
    }
  }
}
```

### 需要修改的字段

| 字段 | 说明 | 示例 |
|------|------|------|
| `baseUrl` | API 地址（OpenAI 兼容格式） | `https://api.deepseek.com/v1` |
| `apiKey` | 你的 API Key | `sk-xxx...` |
| `models[0].id` | 模型标识 | `deepseek-chat` |
| `models[0].name` | 模型名称 | `deepseek-chat` |
| `reasoning` | 推理模型开关 | `true`（如 DeepSeek-R1、MiMo） |

⚠️ **重要**：
- 不要新建 provider，就地替换 `router` 这个 provider 即可
- 其他字段（如 `api`、`input`、`contextWindow`）保持不变

### 支持的模型示例

| 模型 | baseUrl | reasoning |
|------|---------|-----------|
| DeepSeek Chat | `https://api.deepseek.com/v1` | `false` |
| DeepSeek R1 | `https://api.deepseek.com/v1` | `true` |
| MiMo v2.5 Pro | `https://token-plan-sgp.xiaomimimo.com/v1` | `true` |
| GPT-4o | `https://api.openai.com/v1` | `false` |
| 本地 Ollama | `http://localhost:11434/v1` | `false` |

---

## 人设替换（可选）

想自定义 AI 的性格、身份，修改以下文件：

| 文件 | 用途 |
|------|------|
| `workspace/SOUL.md` | 核心性格和行为规则 |
| `workspace/IDENTITY.md` | 名字、形象等身份信息 |
| `workspace/USER.md` | 用户偏好设置 |
| `workspace/AGENTS.md` | 工作空间指南 |

直接编辑这些 `.md` 文件，然后打包还原即可生效。

---

## 打包还原注意事项！！！！

只要 zip 包名和目录结构与原始备份一致，系统还原时能正常识别加载：

1. **包名一致** - 和下载时的 zip 文件名完全相同
2. **目录结构一致** - 顶层目录名也一致（如 `openclaw-1287296976021332797-20260603120000/`）
3. **上传路径一致** - 上传到移动网盘中和下载时相同的路径

---

## 配置信息获取总结

| 你需要的信息 | 获取地址 | 步骤 |
|-------------|---------|------|
| Cloudflare账号 | https://dash.cloudflare.com/ | 注册/登录 |
| Tunnel页面 | Networks → Tunnels | 创建 Tunnel |
| Tunnel ID | 页面顶部 | 直接复制 |
| Account Tag | 「View configuration details」 | 复制32位字符 |
| Tunnel Secret | 创建时一次性显示 | 立即保存 |

---

## 常见问题

### Q: zip 包名不一致会怎样？

还原会失败！系统找不到备份文件。必须保持文件名完全一致。

### Q: 上传路径不对会怎样？

还原时找不到文件。必须上传到和下载时完全相同的路径。

### Q: Tunnel Secret 找不到？

只显示一次。忘了就删除重建 Tunnel，这次立即复制！

---

## 致谢

感谢 [Linux.do](https://linux.do) 社区的支持与贡献：
- **JSW** — 信息资讯分享
- **Yumenosora** — 写给小白的MClaw的轮椅♿️教程分享


---

## 许可证

MIT License