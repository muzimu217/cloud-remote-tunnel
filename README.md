# MClaw 内网穿透配置包

**中国移动 MClaw 备份文件** 内网穿透配置，放入备份文件即可实现远程访问。同时支持**模型替换**自定义 AI。

---

## 核心功能

- ✅ **内网穿透** - Cloudflare Tunnel 远程访问 OpenClaw
- ✅ **模型替换** - 通过备份还原方式替换内置模型

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
openclaw-你的ID-时间戳/
├── agents/
├── devices/
├── workspace/
├── tidb/
├── remote/          ← 把下载的配置包放这里
│   ├── openclaw-tunnel.json
│   ├── cloudflared-config.yml
│   ├── server-start-robust.sh
│   └── ...
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
# 确保包名和原下载文件完全一致
zip -r openclaw-1287296976021332797-20260603120000.zip openclaw-1287296976021332797-20260603120000/
```

上传后在 OpenClaw 管理界面点击 **「还原系统」**。

### 步骤 6：服务器启动

```bash
apt update && apt install -y wget curl procps
cd remote
./server-start-robust.sh
```

---

## 模型替换（可选）

如果想替换内置模型为 DeepSeek、MiMo、GPT 等：

1. 解压备份 zip
2. 编辑 `agents/main/agent/models.json`
3. 把 `baseUrl` 和 `apiKey` 改成你的 API 配置
4. 按上述步骤打包上传还原

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

## 安全提醒

⚠️ `openclaw-tunnel.json` 包含 Tunnel Secret，请勿上传到公开仓库！

---

## 致谢

感谢 [Linux.do](https://linux.do) 社区的支持与贡献：
- **JSW** — 关键技术思路
- **Yumenosora** — 测试反馈
- **Mr.Hua** — 部署优化

---

## 许可证

MIT License