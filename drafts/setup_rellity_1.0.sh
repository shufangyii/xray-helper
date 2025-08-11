#!/bin/bash

#================================================================
# Xray (VLESS + TCP + REALITY) 自动化安装脚本
#
# 版本: 1.0
# 描述:
#   - 专为 REALITY 协议设计，提供顶级防封锁能力。
#   - 无需域名，无需Nginx/Certbot。
#   - 自动开启 BBR。
#
# 支持系统: Ubuntu 20.04+
#
# 注意: 本方案与 VLESS+WS+TLS 方案互斥，请在纯净系统上运行。
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
    echo -e "${BLUE}       Xray (VLESS + TCP + REALITY) 自动化安装脚本        ${PLAIN}"
    echo -e "${BLUE}================================================================${PLAIN}"
    echo

    read -p "请输入服务器监听端口 (默认: 443): " LISTEN_PORT
    [ -z "$LISTEN_PORT" ] && LISTEN_PORT="443"

    read -p "请输入要伪装的目标网站 (默认: www.microsoft.com:443): " DEST_SERVER
    [ -z "$DEST_SERVER" ] && DEST_SERVER="www.microsoft.com:443"
    
    # 从目标网站中提取 serverName
    SERVER_NAME=$(echo $DEST_SERVER | cut -d: -f1)

    echo
    echo -e "${YELLOW}--- 请确认以下信息 ---${PLAIN}"
    echo "监听端口:     ${GREEN}${LISTEN_PORT}${PLAIN}"
    echo "目标网站:     ${GREEN}${DEST_SERVER}${PLAIN}"
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
    apt install -y curl socat ufw openssl
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
    
    # 生成REALITY密钥对、UUID和Short ID
    KEYS=$(xray x25519)
    PRIVATE_KEY=$(echo "$KEYS" | grep "Private key" | awk '{print $3}')
    PUBLIC_KEY=$(echo "$KEYS" | grep "Public key" | awk '{print $3}')
    UUID=$(xray uuid)
    SHORT_ID=$(openssl rand -hex 8)
    
    echo -e "${GREEN}Xray安装及密钥生成完成。${PLAIN}"
}

configure_firewall() {
    echo -e "${BLUE}--> 正在配置防火墙...${PLAIN}"
    ufw allow 22/tcp
    ufw allow ${LISTEN_PORT}/tcp
    ufw --force enable
    echo -e "${GREEN}防火墙配置完成。${PLAIN}"
}

configure_xray() {
    echo -e "${BLUE}--> 正在配置Xray (REALITY)...${PLAIN}"
    SERVER_IP=$(curl -s ip.sb)
    SERVER_NAME=$(echo $DEST_SERVER | cut -d: -f1)

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
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF
    echo -e "${GREEN}Xray (REALITY) 配置完成。${PLAIN}"
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
    echo -e "注意: REALITY协议无需域名，地址请直接使用服务器IP。"
    echo -e "${GREEN}================================================================${PLAIN}"
}

# --- 主程序 ---
main() {
    check_root
    get_user_input
    install_dependencies
    enable_bbr
    install_xray
    configure_firewall
    configure_xray
    restart_services
    show_results
}

main
