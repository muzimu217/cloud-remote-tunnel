# MClaw 内网穿透配置包

将此文件夹放入你的 MClaw 备份文件中，实现内网穿透远程访问。

---

## 使用方法

### 1. 放入备份文件

将本文件夹（`remote`）复制到你的 MClaw 备份根目录：

```
openclaw-你的ID-时间戳/
├── agents/
├── devices/
├── workspace/
├── tidb/
├── remote/          ← 放这里
│   ├── openclaw-tunnel.json
│   ├── cloudflared-config.example.yml
│   ├── server-start-robust.sh
│   └── README.md
└── ...
```

### 2. 配置 Tunnel

编辑 `openclaw-tunnel.json`，将 `XXX...` 替换为你的真实配置：

```json
{
  "AccountTag": "你的AccountTag",
  "TunnelID": "你的TunnelID",
  "TunnelName": "openclaw-tunnel",
  "TunnelSecret": "你的TunnelSecret"
}
```

从 [Cloudflare One Dashboard](https://one.dash.cloudflare.com/) 获取这些信息。

### 3. 创建路由配置

复制示例文件并编辑域名：

```bash
cp cloudflared-config.example.yml cloudflared-config.yml
# 编辑填入你的域名
```

### 4. 打包上传还原

重新打包整个备份目录（文件名保持一致），上传到移动网盘，还原系统。

### 5. 服务器启动

将备份包发到服务器，执行：

```bash
cd remote
./server-start-robust.sh
```

---

## 获取 Cloudflare Tunnel 配置

1. 访问 https://one.dash.cloudflare.com/
2. 进入 **Networks > Tunnels**
3. 创建新 Tunnel
4. 记录 Tunnel ID、Account Tag、Secret

---

## 访问地址

启动后可通过以下地址访问：

- **Web 终端**: `https://你的域名/terminal/`
- **Web 界面**: `https://你的域名/`

---

## 前置依赖（服务器端）

```bash
# Ubuntu/Debian/Dae系统
apt update && apt install -y wget curl procps

# CentOS/RHEL
yum install -y wget curl procps
```

---

## 文件说明

| 文件 | 用途 |
|------|------|
| `openclaw-tunnel.json` | Tunnel 凭证（需填入真实配置） |
| `cloudflared-config.example.yml` | 路由配置示例 |
| `server-start-robust.sh` | 一键启动脚本 |
| `server-start.sh` | 简易版启动脚本 |

---

## 安全提醒

⚠️ `openclaw-tunnel.json` 包含 Tunnel Secret，请勿上传到公开仓库！

---

## 许可证

MIT License