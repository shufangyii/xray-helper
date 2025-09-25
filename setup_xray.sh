#!/bin/bash

#================================================================
# Xray (VLESS + TCP + REALITY) 自动化安装脚本
#
# 版本: 2.0
# 更新:
#   - 全流量走 WARP 出站
#   - 专为 REALITY 协议设计，提供顶级防封锁能力
#   - 无需域名，无需Nginx/Certbot
#   - 自动开启 BBR
#
# 支持系统: 仅 Ubuntu 20.04
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
log() {
  echo -e "[$(date '+%F %T')] $1" | tee -a /var/log/xray_reality_install.log
}

check_root() {
  if [ "$EUID" -ne 0 ]; then
    log "${RED}错误: 本脚本需要以root权限运行！${PLAIN}"
    exit 1
  fi
}

check_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" != "ubuntu" || "$VERSION_ID" != "20.04" ]]; then
      log "${RED}仅支持 Ubuntu 20.04，当前系统: $PRETTY_NAME${PLAIN}"
      exit 1
    fi
  else
    log "${RED}无法检测系统版本，仅支持 Ubuntu 20.04${PLAIN}"
    exit 1
  fi
}

get_user_input() {
  clear
  echo -e "${BLUE}================================================================${PLAIN}"
  echo -e "${BLUE}    Xray (REALITY) + WARP 全流量走出口 自动化安装脚本     ${PLAIN}"
  echo -e "${BLUE}================================================================${PLAIN}"
  echo

  read -p "请输入服务器监听端口 (默认: 443): " LISTEN_PORT
  [ -z "$LISTEN_PORT" ] && LISTEN_PORT="443"

  # 检查端口是否被占用
  if lsof -i TCP:${LISTEN_PORT} | grep LISTEN; then
    log "${RED}端口 ${LISTEN_PORT} 已被占用，请更换端口！${PLAIN}"
    exit 1
  fi

  read -p "请输入要伪装的目标网站 (默认: www.microsoft.com:443): " DEST_SERVER
  [ -z "$DEST_SERVER" ] && DEST_SERVER="www.microsoft.com:443"

  read -p "请输入自定义UUID (留空自动生成): " UUID
  [ -z "$UUID" ] && UUID=""

  read -p "请输入自定义SNI (留空自动提取): " CUSTOM_SNI
  [ -z "$CUSTOM_SNI" ] && CUSTOM_SNI=""

  read -p "请输入流控Flow (默认: xtls-rprx-vision): " FLOW
  [ -z "$FLOW" ] && FLOW="xtls-rprx-vision"

  echo
  read -p "是否启用WARP出站 (y/n, 推荐): " ENABLE_WARP

  echo
  echo -e "${YELLOW}--- 请确认以下信息 ---${PLAIN}"
  echo -e "监听端口:         ${GREEN}${LISTEN_PORT}${PLAIN}"
  echo -e "目标网站:         ${GREEN}${DEST_SERVER}${PLAIN}"
  echo -e "自定义UUID:       ${GREEN}${UUID}${PLAIN}"
  echo -e "自定义SNI:        ${GREEN}${CUSTOM_SNI}${PLAIN}"
  echo -e "流控Flow:         ${GREEN}${FLOW}${PLAIN}"
  echo -e "启用WARP出站:     ${GREEN}${ENABLE_WARP}${PLAIN}"
  echo
  read -p "信息确认无误？(y/n): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    log "${RED}安装已取消。${PLAIN}"
    exit 0
  fi
}

install_dependencies() {
  log "${BLUE}--> 正在更新系统并安装依赖...${PLAIN}"
  apt update && apt upgrade -y
  # 逐一检测并安装依赖，确保每个命令都可用
  local pkgs=(curl socat openssl wget jq lsof)
  for pkg in "${pkgs[@]}"; do
    if ! command -v $pkg >/dev/null 2>&1; then
      log "${YELLOW}未检测到 $pkg，正在安装...${PLAIN}"
      apt install -y $pkg
      if ! command -v $pkg >/dev/null 2>&1; then
        log "${RED}依赖 $pkg 安装失败，请检查网络或源配置。${PLAIN}"
        exit 1
      fi
    fi
  done
  # 检查 systemctl
  if ! command -v systemctl >/dev/null 2>&1; then
    log "${RED}未检测到 systemctl，系统不支持或环境异常。${PLAIN}"
    exit 1
  fi
  log "${GREEN}依赖安装完成。${PLAIN}"
}

enable_bbr() {
  log "${BLUE}--> 正在开启BBR...${PLAIN}"
  if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
    log "${YELLOW}BBR已经开启。${PLAIN}"
    return
  fi
  echo -e "net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  sysctl -p
  if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
    log "${GREEN}BBR已成功开启。${PLAIN}"
  else
    log "${RED}BBR开启失败。${PLAIN}"
  fi
}

check_network() {
  log "检测 GitHub 连接..."
  curl -s --connect-timeout 5 https://github.com > /dev/null
  if [ $? -ne 0 ]; then
    log "${RED}无法连接到 GitHub，请检查网络。${PLAIN}"
    exit 1
  fi
  log "检测 Cloudflare 连接..."
  ping -c 1 -W 2 engage.cloudflareclient.com > /dev/null 2>&1
  if [ $? -ne 0 ]; then
    log "${RED}无法 ping 通 Cloudflare WARP 端点 engage.cloudflareclient.com，请检查网络。${PLAIN}"
    exit 1
  fi
}

install_xray() {
  log "${BLUE}--> 正在安装Xray核心...${PLAIN}"
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  if [ $? -ne 0 ]; then
    log "${RED}Xray安装失败。${PLAIN}"
    exit 1
  fi
  if [ -z "$UUID" ]; then
    UUID=$(xray uuid)
  fi
  KEYS=$(xray x25519)
  PRIVATE_KEY=$(echo "$KEYS" | grep "PrivateKey:" | awk '{print $2}')
  PUBLIC_KEY=$(echo "$KEYS" | grep "Password:" | awk '{print $2}')
  SHORT_ID=$(openssl rand -hex 8)
  log "${GREEN}Xray安装及密钥生成完成。${PLAIN}"
}

configure_warp_outbound() {
  log "${BLUE}--> 正在配置WARP出站接口...${PLAIN}"
  # 下载并准备 wgcf
  wget -O wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.9/wgcf_2.2.9_linux_amd64
  if [ $? -ne 0 ]; then
    log "${RED}wgcf下载失败，请检查网络。${PLAIN}"
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
    log "${RED}无法从wgcf-profile.conf中提取密钥，WARP配置失败。${PLAIN}"
    # 更安全的清理
    shred -u wgcf wgcf-account.toml wgcf-profile.conf 2>/dev/null || rm -f wgcf wgcf-account.toml wgcf-profile.conf
    exit 1
  fi
  # 更安全的清理
  shred -u wgcf wgcf-account.toml wgcf-profile.conf 2>/dev/null || rm -f wgcf wgcf-account.toml wgcf-profile.conf
  log "${GREEN}WARP出站接口配置完成。${PLAIN}"
}


reconfigure_warp() {
  log "${BLUE}--> 重新配置WARP出站（wgcf）...${PLAIN}"
  local tmp_dir=$(mktemp -d)
  local wgcf_bin="$tmp_dir/wgcf"
  local config_file="/usr/local/etc/xray/config.json"
  local backup_cfg="${config_file}.reconfigure-bak.$(date +%s)"

  if [ ! -f "$config_file" ]; then
    log "${RED}未找到 Xray 配置文件 ${config_file}，请先安装或确认路径。${PLAIN}"
    rm -rf "$tmp_dir"
    exit 1
  fi

  # 下载 wgcf
  wget -q -O "$wgcf_bin" https://github.com/ViRb3/wgcf/releases/download/v2.2.9/wgcf_2.2.9_linux_amd64
  if [ $? -ne 0 ]; then
    log "${RED}wgcf 下载失败。${PLAIN}"
    rm -rf "$tmp_dir"
    exit 1
  fi
  chmod +x "$wgcf_bin"

  pushd "$tmp_dir" >/dev/null 2>&1
  # 注册并生成配置（若账号已存在也不会重复创建）
  "$wgcf_bin" register --accept-tos >/dev/null 2>&1 || true
  "$wgcf_bin" generate >/dev/null 2>&1

  # 提取键
  if [ ! -f wgcf-profile.conf ]; then
    log "${RED}wgcf-profile.conf 未生成，wgcf 运行失败。${PLAIN}"
    popd >/dev/null 2>&1
    rm -rf "$tmp_dir"
    exit 1
  fi

  local WGCF_PRIVATE_KEY=$(grep "PrivateKey" wgcf-profile.conf | awk '{print $3}')
  local WGCF_PUBLIC_KEY=$(grep "PublicKey" wgcf-profile.conf | awk '{print $3}')

  if [ -z "$WGCF_PRIVATE_KEY" ] || [ -z "$WGCF_PUBLIC_KEY" ]; then
    log "${RED}无法从 wgcf-profile.conf 提取密钥，重新配置失败。${PLAIN}"
    popd >/dev/null 2>&1
    rm -rf "$tmp_dir"
    exit 1
  fi

  # 备份当前配置
  cp -a "$config_file" "$backup_cfg"
  log "已备份当前配置到 $backup_cfg"

  # 生成 wireguard outbound JSON (使用 secretKey/address/peers)
  local warp_json=$(cat <<EOF
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

  # 将 warp_json 插入或替换到 config.json 的 outbounds 中，并写入 routing
  jq --argjson warp "$warp_json" '
    .outbounds = (.outbounds // []) | 
    (if ((.outbounds | map(select(.protocol=="wireguard")) | length) > 0) 
      then (.outbounds = (.outbounds | map(if .protocol=="wireguard" then $warp else . end))) 
      else (.outbounds = ((.outbounds // []) + [$warp])) end) |
    .outbounds = (.outbounds | map(if .protocol=="wireguard" then .tag = "warp-out" else . end)) |
    .routing = {"rules":[{"type":"field","outboundTag":"warp-out","network":"tcp,udp"}]}
  ' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"

  local jq_ret=$?
  popd >/dev/null 2>&1
  # 清理临时文件（包含 wgcf 相关）
  rm -rf "$tmp_dir"

  if [ $jq_ret -ne 0 ]; then
    log "${RED}更新 config.json 时发生错误，已恢复备份。${PLAIN}"
    mv "$backup_cfg" "$config_file"
    exit 1
  fi

  systemctl restart xray
  if [ $? -ne 0 ]; then
    log "${RED}重启 xray 失败，已恢复备份配置并停止操作。${PLAIN}"
    mv "$backup_cfg" "$config_file"
    exit 1
  fi

  log "${GREEN}WARP 已重新配置并已重启 Xray。备份保存在 ${backup_cfg}${PLAIN}"
}


configure_xray() {
    log "${BLUE}--> 正在配置Xray...${PLAIN}"
    SERVER_IP=$(curl -s ip.sb)
    if [ -n "$CUSTOM_SNI" ]; then
        SERVER_NAME="$CUSTOM_SNI"
    else
        SERVER_NAME=$(echo $DEST_SERVER | cut -d: -f1)
    fi

    # --- reality 私钥校验 ---
    if [ -z "$PRIVATE_KEY" ]; then
        log "${RED}错误：Reality协议私钥为空，无法生成有效配置！${PLAIN}"
        exit 1
    fi

    # --- reality 公钥校验 ---
    if [ -z "$PUBLIC_KEY" ]; then
        log "${RED}错误：Reality协议公钥为空，无法生成有效配置！${PLAIN}"
        exit 1
    fi

    if [ "$ENABLE_WARP" = "y" ] || [ "$ENABLE_WARP" = "Y" ]; then
        outbounds_config=$(cat <<EOF
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
            "flow": "${FLOW}"
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
    # JSON 校验
    if ! jq . /usr/local/etc/xray/config.json > /dev/null 2>&1; then
        log "${RED}Xray配置文件 JSON 语法错误，请检查参数！${PLAIN}"
        cat /usr/local/etc/xray/config.json
        exit 1
    fi
    log "${GREEN}Xray配置完成。${PLAIN}"
}

restart_services() {
  log "${BLUE}--> 正在设置并启动Xray服务（以 root 用户）...${PLAIN}"

  cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000
User=root

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl restart xray
  systemctl enable xray

  log "${GREEN}Xray服务已设置为以 root 用户运行，已启动并设置开机自启。${PLAIN}"
}

show_results() {
  if [ -n "$CUSTOM_SNI" ]; then
    SERVER_NAME="$CUSTOM_SNI"
  else
    SERVER_NAME=$(echo $DEST_SERVER | cut -d: -f1)
  fi
  clear
  echo -e "${GREEN}================================================================${PLAIN}"
  echo -e "${GREEN}      🎉 恭喜！Xray (REALITY) 已成功搭建！ 🎉      ${PLAIN}"
  echo -e "${GREEN}================================================================${PLAIN}"
  echo
  echo -e "${YELLOW}--- 客户端连接参数 ---${PLAIN}"
  echo -e "地址 (Address):      ${GREEN}${SERVER_IP}${PLAIN}"
  echo -e "端口 (Port):         ${GREEN}${LISTEN_PORT}${PLAIN}"
  echo -e "用户ID (UUID):       ${GREEN}${UUID}${PLAIN}"
  echo -e "流控 (Flow):         ${GREEN}${FLOW}${PLAIN}"
  echo -e "加密 (Security):     ${GREEN}reality${PLAIN}"
  echo -e "SNI (Server Name):   ${GREEN}${SERVER_NAME}${PLAIN}"
  echo -e "指纹 (Fingerprint):  ${GREEN}chrome (或其他, 如safari)${PLAIN}"
  echo -e "公钥 (Public Key):   ${GREEN}${PUBLIC_KEY}${PLAIN}"
  echo -e "短ID (Short ID):     ${GREEN}${SHORT_ID}${PLAIN}"
  echo
  echo -e "${YELLOW}--- VLESS 链接 (可直接导入客户端) ---${PLAIN}"
  VLESS_LINK="vless://${UUID}@${SERVER_IP}:${LISTEN_PORT}?encryption=none&flow=${FLOW}&security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#REALITY"
  echo -e "${BLUE}${VLESS_LINK}${PLAIN}"
  echo
  if [ "$ENABLE_WARP" = "y" ] || [ "$ENABLE_WARP" = "Y" ]; then
    echo -e "${YELLOW}WARP全流量出站功能已开启。${PLAIN}"
  fi
  echo -e "${GREEN}================================================================${PLAIN}"
}

uninstall_xray_reality() {
  log "${BLUE}--> 正在卸载Xray及相关配置...${PLAIN}"
  systemctl stop xray 2>/dev/null
  systemctl disable xray 2>/dev/null
  rm -rf /usr/local/etc/xray /usr/local/bin/xray /etc/systemd/system/xray.service
  log "${GREEN}Xray及相关配置已卸载。${PLAIN}"
  echo -e "${GREEN}卸载完成。${PLAIN}"
  exit 0
}

check_status() {
  echo -e "${BLUE}--- Xray Service Status ---${PLAIN}"
  if systemctl is-active --quiet xray; then
    echo -e "Xray Service: ${GREEN}Active (running)${PLAIN}"
    systemctl status xray --no-pager | grep -E 'Active:|Main PID:|Memory:'
  else
    echo -e "Xray Service: ${RED}Inactive or Failed${PLAIN}"
    journalctl -u xray -n 5 --no-pager
    exit 1
  fi
  echo

  local CONFIG_FILE="/usr/local/etc/xray/config.json"
  if [ ! -f "$CONFIG_FILE" ]; then
     echo -e "${RED}Xray config file not found at /usr/local/etc/xray/config.json${PLAIN}"
     exit 1
  fi

  echo -e "${BLUE}--- VLESS Connection Link ---${PLAIN}"
  if ! command -v xray >/dev/null 2>&1; then
    echo -e "${RED}xray command not found, cannot derive public key to generate link.${PLAIN}"
  else
    local UUID=$(jq -r '.inbounds[0].settings.clients[0].id' $CONFIG_FILE)
    local LISTEN_PORT=$(jq -r '.inbounds[0].port' $CONFIG_FILE)
    local FLOW=$(jq -r '.inbounds[0].settings.clients[0].flow' $CONFIG_FILE)
    local SNI=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' $CONFIG_FILE)
    local SHORT_ID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' $CONFIG_FILE)
    local PRIVATE_KEY=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' $CONFIG_FILE)
    local PUBLIC_KEY=$(xray x25519 -i "$PRIVATE_KEY" | grep "Public key" | awk '{print $3}')
    local SERVER_IP=$(curl -s ip.sb)
    
    if [ -z "$SERVER_IP" ] || [ -z "$PUBLIC_KEY" ]; then
        echo -e "${RED}Failed to retrieve server IP or derive public key. Cannot generate link.${PLAIN}"
    else
        VLESS_LINK="vless://${UUID}@${SERVER_IP}:${LISTEN_PORT}?encryption=none&flow=${FLOW}&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#REALITY"
        echo -e "${BLUE}${VLESS_LINK}${PLAIN}"
    fi
  fi
  echo

  echo -e "${BLUE}--- WARP Configuration Status ---${PLAIN}"
  if grep -q '"tag": "warp-out"' $CONFIG_FILE; then
    echo -e "WARP Config: ${GREEN}Enabled in config.json${PLAIN}"
    
    echo
    echo -e "${BLUE}--- Live WARP Connection Test ---${PLAIN}"
    
    if ! command -v dig &> /dev/null; then
      echo -e "${YELLOW}Dependency 'dig' not found. Run 'sudo apt update && sudo apt install dnsutils' to install it.${PLAIN}"
      exit 1
    fi

    local warp_endpoint_host=$(grep -oP '"endpoint": "\K[^"]+' $CONFIG_FILE | cut -d: -f1)
    [ -z "$warp_endpoint_host" ] && warp_endpoint_host="engage.cloudflareclient.com"
    
    local warp_ip=$(dig +short "$warp_endpoint_host" | head -n1)
    if [ -z "$warp_ip" ]; then
      echo -e "${RED}Could not resolve WARP endpoint IP ($warp_endpoint_host). Check DNS or network.${PLAIN}"
      exit 1
    fi
    echo -e "Probing for connection to WARP endpoint: ${GREEN}${warp_ip}${PLAIN}"

    if sudo ss -nup | grep 'pname=xray' | grep -q "$warp_ip"; then
      echo -e "Live Connection: ${GREEN}Established! Xray is connected to WARP.${PLAIN}"
      sudo ss -nup | grep 'pname=xray' | grep "$warp_ip"
    else
      echo -e "Live Connection: ${YELLOW}Not detected.${PLAIN}"
      echo -e "This is normal if no traffic has triggered the WARP outbound rule yet."
      echo -e "Try accessing a site routed through WARP and run this check again."
    fi
  else
    echo -e "WARP Config: ${YELLOW}Not enabled in config.json${PLAIN}"
  fi
  echo
  echo -e "${GREEN}Status check complete.${PLAIN}"
}

# --- 动态切换 WARP/Freedom 出站 ---
switch_warp() {
  local mode="$1"
  local config_file="/usr/local/etc/xray/config.json"
  if [ ! -f "$config_file" ]; then
    echo -e "${RED}未找到Xray配置文件，无法切换。${PLAIN}"
    exit 1
  fi
  local backup_file="/usr/local/etc/xray/warp_out_backup.json"

  if [ "$mode" = "on" ]; then
    # 启用WARP出站：如果 config 已经有 wireguard 出站，仅设置 tag 与 routing；
    # 否则尝试从备份恢复（backup_file），若无备份则提示用户重新运行 configure_warp_outbound
    if jq -e '.outbounds[] | select(.protocol=="wireguard")' "$config_file" >/dev/null 2>&1; then
      jq '(.outbounds[] | select(.protocol=="wireguard") | .tag) = "warp-out" | .routing = {"rules":[{"type":"field","outboundTag":"warp-out","network":"tcp,udp"}]}' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
      systemctl restart xray
      echo -e "${GREEN}已切换为WARP出站，并重启Xray服务。${PLAIN}"
    elif [ -f "$backup_file" ]; then
      # 从备份恢复整个 outbound 对象
      backup_json=$(cat "$backup_file")
      if [ -z "$backup_json" ]; then
        echo -e "${RED}备份文件存在但为空，无法恢复WARP出站。${PLAIN}"
        exit 1
      fi
      # 将 outbounds 替换为备份的 wireguard 配置（保留原有其它出站可能不必要）并添加 routing
      jq --argjson warp "$backup_json" '.outbounds = [$warp] | .outbounds[0].tag = "warp-out" | .routing = {"rules":[{"type":"field","outboundTag":"warp-out","network":"tcp,udp"}]}' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
      systemctl restart xray
      echo -e "${GREEN}已从备份恢复WARP出站并重启Xray服务。${PLAIN}"
    else
      echo -e "${RED}配置中未找到 wireguard 出站，且未发现备份 ($backup_file)。请先运行带 WARP 的安装或手动配置 WARP 出站（configure_warp_outbound）。${PLAIN}"
      exit 1
    fi
  elif [ "$mode" = "off" ]; then
    # 关闭WARP出站：如果存在 wireguard 出站，则备份到 backup_file，然后切换为 freedom 并删除 routing
    if jq -e '.outbounds[] | select(.protocol=="wireguard")' "$config_file" >/dev/null 2>&1; then
      # 以紧凑模式导出该 outbound 对象到备份文件
      jq -c '.outbounds[] | select(.protocol=="wireguard")' "$config_file" > "$backup_file"
      # 切换为 freedom 出站并删除 routing
      jq '.outbounds = [{"protocol":"freedom","settings":{}}] | del(.routing)' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
      systemctl restart xray
      echo -e "${GREEN}已切换为freedom出站，并将原 WARP 出站备份到 ${backup_file}。已重启Xray服务。${PLAIN}"
    else
      # 即使没有 wireguard，也确保 outbounds 为 freedom，并删除 routing
      jq '.outbounds = [{"protocol":"freedom","settings":{}}] | del(.routing)' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
      systemctl restart xray
      echo -e "${YELLOW}配置中未发现 WARP 出站；已将 outbounds 设置为 freedom 并重启Xray。${PLAIN}"
    fi
  else
    echo -e "${RED}参数错误: switch-warp 仅支持 on/off${PLAIN}"
    exit 1
  fi
}

# --- 主程序 ---
show_help() {
  echo "用法: bash $0 [参数]"
  echo
  echo "参数说明:"
  echo "  (无参数)     进入交互式安装流程"
  echo "  help         显示本帮助信息"
  echo "  uninstall    卸载 Xray Reality 及相关配置"
  echo "  status       检查 Xray 和 WARP 的运行状态"
  echo "  reconfigure-warp  重新配置 WARP 出站（wgcf），用于修复或重建 WARP 配置"
  echo "  switch-warp on    切换为WARP出站"
  echo "  switch-warp off   切换为freedom出站"
  echo
  echo "示例:"
  echo "  bash $0           # 交互式安装"
  echo "  bash $0 uninstall # 卸载所有配置"
  echo "  bash $0 status    # 检查运行状态"
  echo "  bash $0 help      # 查看帮助"
  echo "  bash $0 switch-warp on  # 切换为WARP出站"
  echo "  bash $0 switch-warp off # 切换为freedom出站"
  echo "  bash $0 reconfigure-warp  # 重新生成并配置 WARP 出站（故障排查/重置）"
  exit 0
}

main() {
  check_root
  case "$1" in
    help)
      show_help
      ;;
    uninstall)
      uninstall_xray_reality
      ;;
    status)
      check_status
      ;;
    reconfigure-warp)
      reconfigure_warp
      ;;
    switch-warp)
      switch_warp "$2"
      ;;
    "")
  check_os
  install_dependencies
  get_user_input
  check_network
  enable_bbr
  install_xray
  if [ "$ENABLE_WARP" = "y" ] || [ "$ENABLE_WARP" = "Y" ]; then
    configure_warp_outbound
  fi
  configure_xray
  restart_services
  show_results
    ;;
  *)
      echo -e "${RED}未知参数: $1${PLAIN}"
      show_help
    ;;
esac
}

main "$@"
