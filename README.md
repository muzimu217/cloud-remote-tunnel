# MClaw 内网穿透配置包

将此文件夹放入你的 MClaw 备份文件中，实现内网穿透远程访问。

---

## 使用方法

### 步骤 1：下载此配置包

点击右上角 **「Code」** → **「Download ZIP」** 下载，或：

```bash
git clone https://github.com/muzimu217/mclaw-remote-tunnel.git
```

### 步骤 2：放入备份文件

将下载的文件夹内容复制到你的 MClaw 备份根目录：

```
你的备份文件夹/
├── agents/
├── devices/
├── workspace/
├── remote/          ← 把下载的内容放这里
└── ...
```

### 步骤 3：配置 Cloudflare Tunnel（重点！）

#### 3.1 登录 Cloudflare

1. 打开浏览器，访问：**https://dash.cloudflare.com/**
2. 登录你的 Cloudflare 账号（没有账号先注册一个，免费）
3. 登录后，点击左侧菜单 **「Zero Trust」**

#### 3.2 进入 Tunnel 页面

1. 在 Zero Trust 页面，点击左侧 **「Networks」**
2. 再点击 **「Tunnels」**
3. 页面地址：**https://one.dash.cloudflare.com/** → Networks → Tunnels

#### 3.3 创建 Tunnel

1. 点击右上角 **「Create a tunnel」** 按钮
2. 选择 **「Cloudflared」**（不是 WARP）
3. 输入 Tunnel 名称，比如：`openclaw-tunnel`
4. 点击 **「Save tunnel」**

#### 3.4 获取配置信息（关键！）

创建完成后，页面会显示以下信息，**记下来**：

| 字段 | 在页面的位置 | 示例格式 |
|------|-------------|----------|
| **Tunnel ID** | 页面上方，类似 `e040a498-3c43-47ac-82a4-5b2f33132783` | 一串 UUID |
| **Account Tag** | 需要点击「View configuration details」查看 | 一串32位字符 |
| **Tunnel Secret** | 创建时显示的 Token，类似 `RMqY+JgDIo9zaN6jnDq...` | 很长的字符串 |

**注意**：Tunnel Secret 只在创建时显示一次，请立即复制保存！

#### 3.5 填入配置文件

打开 `openclaw-tunnel.json` 文件，填入你刚才记录的信息：

```json
{
  "AccountTag": "你的AccountTag（32位字符）",
  "TunnelID": "你的TunnelID（UUID格式）",
  "TunnelName": "openclaw-tunnel",
  "TunnelSecret": "你的TunnelSecret（长字符串）"
}
```

### 步骤 4：配置域名路由

#### 4.1 准备域名

你需要一个域名托管在 Cloudflare（Cloudflare DNS），没有的话：
1. 在 Cloudflare 首页点击 **「Add a site」**
2. 输入你的域名，按提示添加

#### 4.2 创建路由配置

复制示例文件：

```bash
cp cloudflared-config.example.yml cloudflared-config.yml
```

编辑 `cloudflared-config.yml`，把 `your-domain.example.com` 改成你的真实域名：

```yaml
tunnel: 你的TunnelID
credentials-file: ~/.cloudflared/openclaw-tunnel.json

ingress:
  - hostname: 你的域名.com
    path: /terminal*
    service: http://localhost:7681

  - hostname: 你的域名.com
    service: http://localhost:18789

  - hostname: ssh.你的域名.com
    service: ssh://localhost:22

  - service: http_status:404
```

#### 4.3 DNS 自动配置

不需要手动配置 DNS！Cloudflare Tunnel 会自动为你创建：
- `你的域名.com` → 指向 Tunnel
- `ssh.你的域名.com` → 指向 Tunnel

### 步骤 5：打包上传还原

1. 把整个备份文件夹打包成 zip（文件名和原备份一致！）
2. 上传到移动网盘，替换原备份文件
3. 在 OpenClaw 管理界面点击 **「还原系统」**

### 步骤 6：服务器启动

将备份包发送到服务器后：

```bash
# 安装依赖
apt update && apt install -y wget curl procps

# 进入 remote 目录
cd remote

# 一键启动
chmod +x server-start-robust.sh
./server-start-robust.sh
```

### 步骤 7：验证访问

启动后，访问以下地址测试：

- **Web 终端**: `https://你的域名.com/terminal/`
  - 用户名: `openclaw`
  - 密码: `OpenClaw@2026`
- **Web 界面**: `https://你的域名.com/`

---

## 配置信息获取总结

| 你需要的信息 | 获取地址 | 获取步骤 |
|-------------|---------|---------|
| Cloudflare账号 | https://dash.cloudflare.com/ | 注册/登录 |
| Tunnel配置页面 | https://one.dash.cloudflare.com/ | 左侧 Networks → Tunnels |
| Tunnel ID | 创建 Tunnel 后页面顶部显示 | 直接复制 |
| Account Tag | 点击「View configuration details」 | 复制32位字符串 |
| Tunnel Secret | 创建 Tunnel 时一次性显示 | 立即复制保存 |

---

## 常见问题

### Q: Tunnel Secret 找不到怎么办？

Tunnel Secret 只在创建时显示一次。如果忘了：
1. 在 Tunnels 页面删除原来的 Tunnel
2. 重新创建一个新的 Tunnel
3. 这次一定要立即复制 Secret！

### Q: 域名怎么配置？

只要你把域名托管到 Cloudflare DNS，其他什么都不用做。Tunnel 会自动配置 DNS 记录。

### Q: 启动脚本报错？

检查服务器是否有 wget 或 curl：

```bash
# 安装依赖
apt install -y wget curl procps
```

---

## 安全提醒

⚠️ `openclaw-tunnel.json` 包含 Tunnel Secret，请勿上传到公开仓库！

---

## 致谢

感谢 [Linux.do](https://linux.do) 社区的支持与贡献，特别感谢以下社区成员：

- **JSW** — 提供关键技术思路和指导
- **Yumenosora** — 协助测试与反馈
- **Mr.Hua** — 提供部署经验与优化建议

---

## 许可证

MIT License