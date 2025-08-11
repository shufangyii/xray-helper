#!/bin/bash

#================================================================
# Xray (VLESS + TCP + REALITY) 自动化安装脚本
#
# 版本: 2.0
# 更新:
#   - 新增 可选的WARP出站分流功能，解决VPS IP被目标网站封锁的问题
#   - 专为 REALITY 协议设计，提供顶级防封锁能力
#   - 无需域名，无需Nginx/Certbot
#   - 自动开启 BBR
#
# 支持系统: Ubuntu 20.04+
#================================================================

# --- 颜色定义 ---
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
PLAIN="\033[0m"

# --- 全局变量 ---
LISTEN_PORT=""
DEST_SERVER=""
SERVER_IP=""
UUID=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""

ENABLE_WARP="n"
WGCF_PRIVATE_KEY=""
WGCF_PUBLIC_KEY=""
WGCF_ENDPOINT="engage.cloudflareclient.com:2408" # 默认值

# --- 函数定义 ---

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误: 本脚本需要以root权限运行！${PLAIN}"
        exit 1
    fi
}

get_user_input() {
    clear
    echo -e "${BLUE}================================================================${PLAIN}"
    echo -e "${BLUE}    Xray (REALITY) + WARP 出站分流 自动化安装脚本     ${PLAIN}"
    echo -e "${BLUE}================================================================${PLAIN}"
    echo

    read -p "请输入服务器监听端口 (默认: 443): " LISTEN_PORT
    [ -z "$LISTEN_PORT" ] && LISTEN_PORT="443"

    read -p "请输入要伪装的目标网站 (默认: www.microsoft.com:443): " DEST_SERVER
    [ -z "$DEST_SERVER" ] && DEST_SERVER="www.microsoft.com:443"
    
    echo
    read -p "是否启用WARP出站分流 (y/n, 推荐, 用于解锁Google字体等): " ENABLE_WARP

    echo
    echo -e "${YELLOW}--- 请确认以下信息 ---${PLAIN}"
    echo "监听端口:         ${GREEN}${LISTEN_PORT}${PLAIN}"
    echo "目标网站:         ${GREEN}${DEST_SERVER}${PLAIN}"
    echo "启用WARP分流:     ${GREEN}${ENABLE_WARP}${PLAIN}"
    echo
    read -p "信息确认无误？(y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo -e "${RED}安装已取消。${PLAIN}"
        exit 0
    fi
}

install_dependencies() {
    echo -e "${BLUE}--> 正在更新系统并安装依赖...${PLAIN}"
    apt update && apt upgrade -y
    apt install -y curl socat ufw openssl wget
    if [ $? -ne 0 ]; then
        echo -e "${RED}依赖安装失败。${PLAIN}"
        exit 1
    fi
    echo -e "${GREEN}依赖安装完成。${PLAIN}"
}

enable_bbr() {
    echo -e "${BLUE}--> 正在开启BBR...${PLAIN}"
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo -e "${YELLOW}BBR已经开启。${PLAIN}"
        return
    fi
    
    cat >> /etc/sysctl.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl -p
    
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo -e "${GREEN}BBR已成功开启。${PLAIN}"
    else
        echo -e "${RED}BBR开启失败。${PLAIN}"
    fi
}

install_xray() {
    echo -e "${BLUE}--> 正在安装Xray核心...${PLAIN}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    if [ $? -ne 0 ]; then
        echo -e "${RED}Xray安装失败。${PLAIN}"
        exit 1
    fi
    
    KEYS=$(xray x25519)
    PRIVATE_KEY=$(echo "$KEYS" | grep "Private key" | awk '{print $3}')
    PUBLIC_KEY=$(echo "$KEYS" | grep "Public key" | awk '{print $3}')
    UUID=$(xray uuid)
    SHORT_ID=$(openssl rand -hex 8)
    
    echo -e "${GREEN}Xray安装及密钥生成完成。${PLAIN}"
}

configure_warp_outbound() {
    echo -e "${BLUE}--> 正在配置WARP出站接口...${PLAIN}"
    
    # 下载并准备 wgcf
    wget -O wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.9/wgcf_2.2.9_linux_amd64
    if [ $? -ne 0 ]; then
        echo -e "${RED}wgcf下载失败，请检查网络。${PLAIN}"
        exit 1
    fi
    chmod +x wgcf
    
    # 生成配置
    ./wgcf register --accept-tos
    ./wgcf generate
    
    # 提取所需信息
    WGCF_PRIVATE_KEY=$(grep "PrivateKey" wgcf-profile.conf | awk '{print $3}')
    WGCF_PUBLIC_KEY=$(grep "PublicKey" wgcf-profile.conf | awk '{print $3}')
    
    if [ -z "$WGCF_PRIVATE_KEY" ] || [ -z "$WGCF_PUBLIC_KEY" ]; then
        echo -e "${RED}无法从wgcf-profile.conf中提取密钥，WARP配置失败。${PLAIN}"
        # 清理
        rm -f wgcf wgcf-account.toml wgcf-profile.conf
        exit 1
    fi
    
    # 清理
    rm -f wgcf wgcf-account.toml wgcf-profile.conf
    
    echo -e "${GREEN}WARP出站接口配置完成。${PLAIN}"
}


configure_firewall() {
    echo -e "${BLUE}--> 正在配置防火墙...${PLAIN}"
    ufw allow 22/tcp
    ufw allow ${LISTEN_PORT}/tcp
    ufw --force enable
    echo -e "${GREEN}防火墙配置完成。${PLAIN}"
}

configure_xray() {
    echo -e "${BLUE}--> 正在配置Xray...${PLAIN}"
    SERVER_IP=$(curl -s ip.sb)
    SERVER_NAME=$(echo $DEST_SERVER | cut -d: -f1)

    # 根据是否启用WARP来构建不同的outbounds和routing
    local outbounds_config
    local routing_config

    if [ "$ENABLE_WARP" = "y" ] || [ "$ENABLE_WARP" = "Y" ]; then
        outbounds_config=$(cat <<EOF
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "wireguard",
      "tag": "warp-out",
      "settings": {
        "secretKey": "${WGCF_PRIVATE_KEY}",
        "address": [ "172.16.0.2/32" ],
        "peers": [
          {
            "publicKey": "${WGCF_PUBLIC_KEY}",
            "endpoint": "${WGCF_ENDPOINT}"
          }
        ]
      }
    }
EOF
)
        routing_config=$(cat <<EOF
  ,
  "routing": {
    "rules": [
      {
        "type": "field",
        "outboundTag": "warp-out",
        "domain": [
          "domain:googleapis.com",
          "domain:gstatic.com",
          "domain:ggpht.com",
          "domain:googleusercontent.com",
          "domain:cdn.jsdelivr.net"
        ]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "network": "tcp,udp"
      }
    ]
  }
EOF
)
    else
        outbounds_config=$(cat <<EOF
    {
      "protocol": "freedom",
      "settings": {}
    }
EOF
)
        routing_config=""
    fi

    # 最终生成config.json
    cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${LISTEN_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST_SERVER}",
          "xver": 0,
          "serverNames": [
            "${SERVER_NAME}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    ${outbounds_config}
  ]
  ${routing_config}
}
EOF
    echo -e "${GREEN}Xray配置完成。${PLAIN}"
}

restart_services() {
    echo -e "${BLUE}--> 正在启动Xray服务...${PLAIN}"
    systemctl restart xray
    systemctl enable xray
    echo -e "${GREEN}Xray服务已启动并设置为开机自启。${PLAIN}"
}

show_results() {
    SERVER_NAME=$(echo $DEST_SERVER | cut -d: -f1)
    clear
    echo -e "${GREEN}================================================================${PLAIN}"
    echo -e "${GREEN}      🎉 恭喜！Xray (REALITY) 已成功搭建！ 🎉      ${PLAIN}"
    echo -e "${GREEN}================================================================${PLAIN}"
    echo
    echo -e "${YELLOW}--- 客户端连接参数 ---${PLAIN}"
    echo -e "地址 (Address):      ${GREEN}${SERVER_IP}${PLAIN}"
    echo -e "端口 (Port):         ${GREEN}${LISTEN_PORT}${PLAIN}"
    echo -e "用户ID (UUID):       ${GREEN}${UUID}${PLAIN}"
    echo -e "流控 (Flow):         ${GREEN}xtls-rprx-vision${PLAIN}"
    echo -e "加密 (Security):     ${GREEN}reality${PLAIN}"
    echo -e "SNI (Server Name):   ${GREEN}${SERVER_NAME}${PLAIN}"
    echo -e "指纹 (Fingerprint):  ${GREEN}chrome (或其他, 如safari)${PLAIN}"
    echo -e "公钥 (Public Key):   ${GREEN}${PUBLIC_KEY}${PLAIN}"
    echo -e "短ID (Short ID):     ${GREEN}${SHORT_ID}${PLAIN}"
    echo
    echo -e "${YELLOW}--- VLESS 链接 (可直接导入客户端) ---${PLAIN}"
    VLESS_LINK="vless://${UUID}@${SERVER_IP}:${LISTEN_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#REALITY"
    echo -e "${BLUE}${VLESS_LINK}${PLAIN}"
    echo
    if [ "$ENABLE_WARP" = "y" ] || [ "$ENABLE_WARP" = "Y" ]; then
        echo -e "${YELLOW}WARP出站分流功能已开启。访问Google字体等被屏蔽资源时将自动切换IP。${PLAIN}"
    fi
    echo -e "${GREEN}================================================================${PLAIN}"
}

# --- 主程序 ---
main() {
    check_root
    get_user_input
    install_dependencies
    enable_bbr
    install_xray
    
    if [ "$ENABLE_WARP" = "y" ] || [ "$ENABLE_WARP" = "Y" ]; then
        configure_warp_outbound
    fi
    
    configure_firewall
    configure_xray
    restart_services
    show_results
}

main