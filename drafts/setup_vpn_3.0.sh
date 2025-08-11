#!/bin/bash

#================================================================
# Xray (VLESS + WebSocket + TLS) + Nginx 自动化安装脚本
#
# 版本: 3.0
# 更新:
#   - 新增 可选的真实网站伪装功能
#   - 自动开启 BBR 拥塞控制算法以加速网络
#   - 在安装结束后提供详细的 Cloudflare CDN 配置指引
#
# 支持系统: Ubuntu 20.04+
#
# 在使用前，请确认：
# 1. 一个域名已经解析到本VPS的IP地址
# 2. 本脚本需要以root权限运行
#================================================================

# --- 颜色定义 ---
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
PLAIN="\033[0m"

# --- 全局变量 ---
DOMAIN=""
SECRET_PATH=""
EMAIL=""
UUID=""
INSTALL_WEBSITE="n"

# --- 函数定义 ---

# 检查是否为root用户
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误: 本脚本需要以root权限运行！${PLAIN}"
        exit 1
    fi
}

# 获取用户输入
get_user_input() {
    clear
    echo -e "${BLUE}================================================================${PLAIN}"
    echo -e "${BLUE}    Xray (VLESS + WS + TLS) + BBR + CDN 自动化安装脚本    ${PLAIN}"
    echo -e "${BLUE}================================================================${PLAIN}"
    echo

    # 获取域名
    while true; do
        read -p "请输入你的域名 (例如: vpn.yourdomain.com): " DOMAIN
        if [ -z "$DOMAIN" ]; then
            echo -e "${RED}域名不能为空，请重新输入！${PLAIN}"
        else
            break
        fi
    done

    # 获取伪装路径
    read -p "请输入你的伪装路径 (默认: /vless): " SECRET_PATH
    [ -z "$SECRET_PATH" ] && SECRET_PATH="/vless"
    # 确保路径以 / 开头
    if [[ ! "$SECRET_PATH" =~ ^/ ]]; then
        SECRET_PATH="/${SECRET_PATH}"
    fi

    # 获取邮箱
    while true; do
        read -p "请输入你的邮箱 (用于申请SSL证书): " EMAIL
        if [ -z "$EMAIL" ]; then
            echo -e "${RED}邮箱不能为空，请重新输入！${PLAIN}"
        else
            break
        fi
    done
    
    # 询问是否安装伪装网站
    read -p "是否安装一个伪装网站来替代Nginx默认页面? (y/n, 推荐): " INSTALL_WEBSITE

    echo
    echo -e "${YELLOW}--- 请确认以下信息 ---${PLAIN}"
    echo "域名:             ${GREEN}${DOMAIN}${PLAIN}"
    echo "伪装路径:         ${GREEN}${SECRET_PATH}${PLAIN}"
    echo "邮箱:             ${GREEN}${EMAIL}${PLAIN}"
    echo "安装伪装网站:     ${GREEN}${INSTALL_WEBSITE}${PLAIN}"
    echo
    read -p "信息确认无误？(y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo -e "${RED}安装已取消。${PLAIN}"
        exit 0
    fi
}

# 更新系统并安装依赖
install_dependencies() {
    echo -e "${BLUE}--> 正在更新系统并安装依赖...${PLAIN}"
    apt update && apt upgrade -y
    apt install -y nginx curl socat certbot python3-certbot-nginx ufw unzip
    if [ $? -ne 0 ]; then
        echo -e "${RED}依赖安装失败，请检查网络或系统源。${PLAIN}"
        exit 1
    fi
    echo -e "${GREEN}依赖安装完成。${PLAIN}"
}

# 开启BBR
enable_bbr() {
    echo -e "${BLUE}--> 正在开启BBR拥塞控制算法...${PLAIN}"
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo -e "${YELLOW}BBR已经开启，无需重复设置。${PLAIN}"
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

# 安装Xray
install_xray() {
    echo -e "${BLUE}--> 正在安装Xray核心...${PLAIN}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    if [ $? -ne 0 ]; then
        echo -e "${RED}Xray安装失败。${PLAIN}"
        exit 1
    fi
    UUID=$(xray uuid)
    echo -e "${GREEN}Xray安装完成。${PLAIN}"
}

# 配置防火墙
configure_firewall() {
    echo -e "${BLUE}--> 正在配置防火墙...${PLAIN}"
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw --force enable
    echo -e "${GREEN}防火墙配置完成。${PLAIN}"
}

# 申请SSL证书并配置Nginx
configure_nginx_and_ssl() {
    echo -e "${BLUE}--> 正在申请SSL证书并配置Nginx...${PLAIN}"
    systemctl stop nginx
    certbot certonly --standalone --non-interactive --agree-tos -m "$EMAIL" -d "$DOMAIN"
    if [ $? -ne 0 ]; then
        echo -e "${RED}SSL证书申请失败。请检查域名解析是否正确，或稍后再试。${PLAIN}"
        exit 1
    fi

    cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384";

    root /var/www/html;
    index index.html index.htm;

    location ${SECRET_PATH} {
        if (\$http_upgrade != "websocket") {
            return 404;
        }
        proxy_pass http://127.0.0.1:10086;
        proxy_redirect off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
    echo -e "${GREEN}Nginx配置完成。${PLAIN}"
}

# 配置伪装网站
configure_camouflage_website() {
    echo -e "${BLUE}--> 正在配置伪装网站...${PLAIN}"
    local TEMPLATE_URL="https://github.com/StartBootstrap/startbootstrap-clean-blog/archive/refs/heads/master.zip"
    
    # 下载模板
    wget -O /tmp/template.zip "$TEMPLATE_URL"
    if [ $? -ne 0 ]; then
        echo -e "${RED}伪装网站模板下载失败。${PLAIN}"
        return
    fi
    
    # 清理旧文件并解压
    rm -rf /var/www/html/*
    unzip -o /tmp/template.zip -d /tmp/
    
    # 将解压后的文件移动到网站根目录
    mv /tmp/startbootstrap-clean-blog-master/* /var/www/html/
    
    # 清理临时文件
    rm -f /tmp/template.zip
    rm -rf /tmp/startbootstrap-clean-blog-master
    
    echo -e "${GREEN}伪装网站配置完成。${PLAIN}"
}


# 配置Xray
configure_xray() {
    echo -e "${BLUE}--> 正在配置Xray...${PLAIN}"
    cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 10086,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-direct"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "${SECRET_PATH}"
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
    echo -e "${GREEN}Xray配置完成。${PLAIN}"
}

# 重启服务
restart_services() {
    echo -e "${BLUE}--> 正在重启服务...${PLAIN}"
    systemctl restart xray
    systemctl restart nginx
    systemctl enable xray
    systemctl enable nginx
    echo -e "${GREEN}服务已启动并设置为开机自启。${PLAIN}"
}

# 显示结果
show_results() {
    clear
    echo -e "${GREEN}================================================================${PLAIN}"
    echo -e "${GREEN}          🎉 恭喜！基础服务已成功搭建！ 🎉          ${PLAIN}"
    echo -e "${GREEN}================================================================${PLAIN}"
    echo
    echo -e "${YELLOW}--- 客户端连接参数 (直连) ---${PLAIN}"
    echo -e "地址 (Address):      ${GREEN}${DOMAIN}${PLAIN}"
    echo -e "端口 (Port):         ${GREEN}443${PLAIN}"
    echo -e "用户ID (UUID):       ${GREEN}${UUID}${PLAIN}"
    echo -e "传输协议 (Network):  ${GREEN}ws (websocket)${PLAIN}"
    echo -e "伪装路径 (Path):     ${GREEN}${SECRET_PATH}${PLAIN}"
    echo -e "底层传输安全 (TLS):  ${GREEN}tls${PLAIN}"
    echo
    echo -e "${YELLOW}--- VLESS 链接 (可直接导入客户端) ---${PLAIN}"
    VLESS_LINK="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=ws&path=${SECRET_PATH//\//%2F}#${DOMAIN}_direct"
    echo -e "${BLUE}${VLESS_LINK}${PLAIN}"
    echo
    if [ "$INSTALL_WEBSITE" = "y" ] || [ "$INSTALL_WEBSITE" = "Y" ]; then
        echo -e "直接访问 https://${DOMAIN} 会显示一个伪装的博客网站。"
    else
        echo -e "直接访问 https://${DOMAIN} 会显示Nginx的欢迎页面。"
    fi
    echo -e "${GREEN}================================================================${PLAIN}"
    echo
}

# 显示Cloudflare配置指引
show_cloudflare_instructions() {
    echo -e "${YELLOW}================================================================${PLAIN}"
    echo -e "${YELLOW}    🚀 下一步：配置Cloudflare CDN以隐藏IP并加速 (强烈推荐) 🚀    ${PLAIN}"
    echo -e "${YELLOW}================================================================${PLAIN}"
    echo
    echo -e "为了防止IP被封锁并获得全球加速效果，请按照以下步骤操作："
    echo
    echo -e "${GREEN}1. 登录Cloudflare官网:${PLAIN} 前往 https://www.cloudflare.com/ 注册并登录。"
    echo
    echo -e "${GREEN}2. 添加你的域名:${PLAIN} 将你的主域名 (例如 yourdomain.com) 添加到Cloudflare。"
    echo
    echo -e "${GREEN}3. 修改NS服务器:${PLAIN} 在你的域名注册商后台，将域名的NS服务器修改为Cloudflare提供的两个地址。"
    echo
    echo -e "${GREEN}4. 配置DNS记录:${PLAIN}"
    echo -e "   - 在Cloudflare的DNS设置页面，找到你的域名记录。"
    echo -e "   - 确保记录类型为 ${BLUE}A${PLAIN}，名称为你的子域名 (如 vpn)，内容为你的VPS IP地址。"
    echo -e "   - ${RED}关键: 确保“代理状态”为“已代理”，云朵图标必须是【橙色】的！${PLAIN}"
    echo
    echo -e "${GREEN}5. 配置SSL/TLS:${PLAIN}"
    echo -e "   - 前往“SSL/TLS”设置页面。"
    echo -e "   - 将加密模式设置为 ${BLUE}“完全(严格)” (Full (Strict))${PLAIN}。"
    echo
    echo -e "${GREEN}6. 开启WebSocket:${PLAIN}"
    echo -e "   - 前往“网络(Network)”设置页面。"
    echo -e "   - 确保 ${BLUE}WebSocket${PLAIN} 功能已开启 (默认开启)。"
    echo
    echo -e "${GREEN}7. 完成!${PLAIN} 等待几分钟生效后，你的客户端配置【无需任何更改】，即可享受CDN带来的保护和加速。"
    echo
    echo -e "${YELLOW}================================================================${PLAIN}"
}


# --- 主程序 ---
main() {
    check_root
    get_user_input
    install_dependencies
    enable_bbr
    install_xray
    configure_firewall
    configure_nginx_and_ssl
    
    if [ "$INSTALL_WEBSITE" = "y" ] || [ "$INSTALL_WEBSITE" = "Y" ]; then
        configure_camouflage_website
    fi

    configure_xray
    restart_services
    show_results
    show_cloudflare_instructions
}

main
