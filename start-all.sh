#!/bin/bash
echo "Starting OpenClaw Gateway..."
openclaw gateway run &

echo "Starting ttyd Web Terminal..."
/home/node/ttyd -p 7681 -W -b /terminal -c openclaw:OpenClaw@2026 bash &

sleep 3

echo "Starting Cloudflare Tunnel..."
nohup ~/.local/bin/cloudflared tunnel --config ~/.cloudflared/config.yml run > ~/.cloudflared/tunnel.log 2>&1 &

sleep 3
echo "=== Status ==="
ps aux | grep -E "cloudflared|ttyd|openclaw" | grep -v grep
