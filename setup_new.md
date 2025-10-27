## 安装使用 V2RAY

1. [233boy 安装脚本](https://github.com/233boy/v2ray/tree/master)
2. 使用 VLESS+WS+TLS

## 使用 CF 代理

1. 在域名解析处开启代理

## 使用 WARP 出站

1. 安装 WARP

```bash
# 1) 导入 Cloudflare 的签名公钥（作为 keyring）
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
  | sudo gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

# 2) 添加 apt 源（会自动替换为你系统的代号，如 jammy）
echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/cloudflare-client.list

# 3) 更新并安装 cloudflare-warp 包
sudo apt update
sudo apt install cloudflare-warp -y

# 4) 启动服务并注册（首次连接）
sudo systemctl enable --now warp-svc
sudo warp-cli registration new        # 注册客户端（首次使用）
sudo warp-cli mode proxy              # 启用代理模式。默认模式会影响SSH
sudo warp-cli connect                 # 连接 WARP 隧道

# 5) 检查状态与验证（返回 warp=on 表示隧道已生效）
warp-cli status
curl https://www.cloudflare.com/cdn-cgi/trace/ | sed -n '1,120p'
# 在输出里查找 warp=off

curl -x 127.0.0.1:40000  https://www.cloudflare.com/cdn-cgi/trace/ | sed -n '1,120p'
# 在输出里查找 warp=on
```

2. 设置 V2RAY

```json
{
  // ...
  "routing": {
    "rules": [
      // ...
      // 新增 👇
      {
        "type": "field",
        "inboundTag": ["VLESS-WS-TLS-s.mrtrees.top.json"],
        "outboundTag": "warp-out"
      }
    ]
  },
  // ...
  "outbounds": [
    // ...
    // 新增 👇
    {
      "tag": "warp-out",
      "protocol": "socks",
      "settings": {
        "servers": [
          {
            "address": "127.0.0.1",
            "port": 40000
          }
        ]
      }
    }
  ]
}
```

3. 重启 V2RAY

```bash
systemctl restart v2ray
journalctl -u v2ray -n 50
```
