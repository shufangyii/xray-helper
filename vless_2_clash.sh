#!/bin/bash
# VLESS → Clash Verge 配置生成器 (v3.0)
# 改进:
# - 生成完整的 Clash 配置，包含通用设置、DNS、代理组和规则
# - 内置常用分流规则 (国内直连、国外代理、广告拦截等)
# - 支持从命令行参数读取链接
# - 自动解析URL中的节点名 (#) 作为代理名和文件名
# - 改进URL参数解析，支持URL解码

set -e

# ===== 颜色定义 =====
COLOR_GREEN="\033[32m"
COLOR_RED="\033[31m"
COLOR_YELLOW="\033[33m"
COLOR_RESET="\033[0m"

# ===== 依赖检查 =====
require_dep() {
  local pkg="$1"; local bin="$2"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo -e "${COLOR_YELLOW}缺少依赖: ${pkg}，请先安装后重试${COLOR_RESET}"
    exit 1
  fi
}
require_dep sed sed
require_dep curl curl

# ===== URL 解码函数 =====
url_decode() {
  local url_encoded="${1//+/ }"
  printf '%b' "${url_encoded//%/\\x}"
}

# ===== 解析 VLESS 链接，返回所有参数 =====
parse_vless_url() {
  local url="$1"
  local raw="${url#vless://}"
  local uuid="${raw%%@*}"
  local remainder="${raw#*@}"
  local addr_port="${remainder%%\?*}"
  local host="${addr_port%%:*}"
  local port="${addr_port##*:}"
  local query_and_fragment="${remainder#*?}"
  local query_string="${query_and_fragment%%#*}"
  local fragment=""
  if [[ "$url" == *#* ]]; then
    fragment="${url#*#}"
  fi

  # 解析节点名称
  local name
  if [[ "$url" != *"#"* || -z "$fragment" || "$fragment" == "$query_and_fragment" ]]; then
    name="VLESS-Imported"
  else
    name=$(url_decode "$fragment")
  fi
  local output_file="clash-${name// /_}.yaml"

  # 解析 URL 参数
  local PATH_PARAM SECURITY SNI TYPE FLOW FP PBK SID ENCRYPTION
  IFS='&' read -ra params_array <<< "$query_string"
  for param in "${params_array[@]}"; do
    local key="${param%%=*}"
    local value="${param#*=}"
    key=$(url_decode "$key")
    value=$(url_decode "$value")
    case "$key" in
      path) PATH_PARAM="$value" ;;
      security) SECURITY="$value" ;;
      sni) SNI="$value" ;;
      type) TYPE="$value" ;;
      flow) FLOW="$value" ;;
      fp) FP="$value" ;;
      pbk) PBK="$value" ;;
      sid) SID="$value" ;;
      encryption) ENCRYPTION="$value" ;;
    esac
  done

  # 设置默认值
  TYPE=${TYPE:-tcp}
  VLESS_PATH=${PATH_PARAM:-/}
  SECURITY=${SECURITY:-reality}
  ENCRYPTION=${ENCRYPTION:-none}

  local TLS SKIP_CERT_VERIFY
  if [[ "$SECURITY" == "tls" || "$SECURITY" == "reality" ]]; then
    TLS=true
    SKIP_CERT_VERIFY=false
  else
    TLS=false
    SKIP_CERT_VERIFY=true
  fi

  # 以字符串形式返回所有参数
  echo "$uuid|$host|$port|$name|$output_file|$TYPE|$VLESS_PATH|$SECURITY|$ENCRYPTION|$TLS|$SKIP_CERT_VERIFY|$SNI|$FLOW|$FP|$PBK|$SID"
}


# ===== 生成 Clash 配置文件 =====

build_proxy_yaml() {
  local NAME="$1" HOST="$2" PORT="$3" UUID="$4" TYPE="$5" TLS="$6" SKIP_CERT_VERIFY="$7" SNI="$8" FLOW="$9" ENCRYPTION="${10}" FP="${11}" PBK="${12}" SID="${13}" VLESS_PATH="${14}" SECURITY="${15}"
  local yaml="  - name: \"$NAME\"\n"
  yaml+="    type: vless\n"
  yaml+="    server: $HOST\n"
  yaml+="    port: $PORT\n"
  yaml+="    uuid: $UUID\n"
  yaml+="    network: $TYPE\n"
  yaml+="    tls: $TLS\n"
  yaml+="    udp: true\n"
  yaml+="    skip-cert-verify: $SKIP_CERT_VERIFY\n"
  yaml+="    servername: ${SNI:-$HOST}\n"
  [[ -n "$FLOW" ]] && yaml+="    flow: $FLOW\n"
  [[ -n "$ENCRYPTION" ]] && yaml+="    encryption: $ENCRYPTION\n"
  [[ -n "$FP" ]] && yaml+="    client-fingerprint: $FP\n"
  if [[ "$SECURITY" == "reality" ]]; then
    yaml+="    reality-opts:\n"
    [[ -n "$PBK" ]] && yaml+="      public-key: $PBK\n"
    [[ -n "$SID" ]] && yaml+="      short-id: $SID\n"
    [[ -n "$FP" ]] && yaml+="      fingerprint: $FP\n"
  fi
  if [[ "$TYPE" == "ws" ]]; then
    yaml+="    ws-opts:\n"
    yaml+="      path: \"$VLESS_PATH\"\n"
    yaml+="      headers:\n"
    yaml+="        Host: ${SNI:-$HOST}\n"
  fi
  echo -e "$yaml"
}

write_clash_config() {
    local NAME="$1" HOST="$2" PORT="$3" UUID="$4" TYPE="$5" TLS="$6" SKIP_CERT_VERIFY="$7" SNI="$8" FLOW="$9" ENCRYPTION="${10}" FP="${11}" PBK="${12}" SID="${13}" VLESS_PATH="${14}" OUTPUT_FILE="${15}" SECURITY="${16}"
    local proxy_yaml
    proxy_yaml="$(build_proxy_yaml "$NAME" "$HOST" "$PORT" "$UUID" "$TYPE" "$TLS" "$SKIP_CERT_VERIFY" "$SNI" "$FLOW" "$ENCRYPTION" "$FP" "$PBK" "$SID" "$VLESS_PATH" "$SECURITY")"
    cat > "$OUTPUT_FILE" << 'EOF'
# Clash Verge 配置文件 (由 vless_2_clash.sh v3.0 生成)

# --- 基础配置 (General) ---
port: 7890
socks-port: 7891
allow-lan: true
mode: rule
log-level: info
external-controller: '127.0.0.1:9090'

# --- DNS 配置 ---
dns:
  enable: true
  listen: 0.0.0.0:53
  ipv6: false
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  enhanced-mode: redir-host
  nameserver:
    - https://dns.alidns.com/dns-query
    - https://doh.pub/dns-query
  fallback:
    - https://cloudflare-dns.com/dns-query
    - https://dns.google/dns-query
    - tls://8.8.4.4:853
  fallback-filter:
    geoip: true
    geoip-code: CN

# --- 代理节点 (Proxies) ---
proxies:
EOF
    echo "$proxy_yaml" >> "$OUTPUT_FILE"
    cat >> "$OUTPUT_FILE" <<EOF

# --- 代理组 (Proxy Groups) ---
proxy-groups:
  - name: "🚀 节点选择"
    type: select
    proxies:
      - "$NAME"
      - DIRECT
      - REJECT

  - name: "📈 国外流量"
    type: select
    proxies:
      - "🚀 节点选择"
      - "$NAME"
      - DIRECT

  - name: "🎯 国内流量"
    type: select
    proxies:
      - DIRECT
      - "🚀 节点选择"

  - name: "Ⓜ️ 微软服务"
    type: select
    proxies:
      - DIRECT
      - "🚀 节点选择"

  - name: "📢 Telegram"
    type: select
    proxies:
      - "🚀 节点选择"
      - DIRECT

  - name: "🍎 苹果服务"
    type: select
    proxies:
      - "🚀 节点选择"
      - DIRECT

# --- 路由规则 (Rules) ---
# 基于常见的规则集进行简化
rules:
  # 广告拦截
  - DOMAIN-SUFFIX,ad.com,REJECT
  # 微软服务
  - DOMAIN-SUFFIX,microsoft.com,Ⓜ️ 微软服务
  - DOMAIN-SUFFIX,live.com,Ⓜ️ 微软服务
  - DOMAIN-SUFFIX,office.com,Ⓜ️ 微软服务
  # 苹果服务
  - DOMAIN-SUFFIX,apple.com,🍎 苹果服务
  - DOMAIN-SUFFIX,icloud.com,🍎 苹果服务
  # Telegram
  - DOMAIN-KEYWORD,telegram,📢 Telegram
  # 国内网站
  - DOMAIN-SUFFIX,cn,🎯 国内流量
  - DOMAIN-KEYWORD,baidu,🎯 国内流量
  - DOMAIN-KEYWORD,tencent,🎯 国内流量
  - DOMAIN-KEYWORD,alibaba,🎯 国内流量
  - DOMAIN-KEYWORD,bilibili,🎯 国内流量
  - DOMAIN-KEYWORD,netease,🎯 国内流量
  # 本地/局域网
  - GEOIP,LAN,DIRECT
  # 国内IP
  - GEOIP,CN,🎯 国内流量
  # 最终匹配
  - MATCH,📈 国外流量
EOF
}

# ===== main 入口 =====

main() {
  # 依赖检查已在全局做过
  local VLESS_URL="$1"
  if [ -z "$VLESS_URL" ]; then
    echo -e "${COLOR_YELLOW}请输入 VLESS 链接:${COLOR_RESET}"
    read -r VLESS_URL
  else
    echo -e "${COLOR_GREEN}从命令行参数读取 VLESS 链接。${COLOR_RESET}"
  fi

  if [[ ! "$VLESS_URL" =~ ^vless:// ]]; then
    echo -e "${COLOR_RED}错误: 请输入有效的 VLESS 链接（以 vless:// 开头）${COLOR_RESET}"
    exit 1
  fi

  # 解析 VLESS 链接
  local parsed
  parsed="$(parse_vless_url "$VLESS_URL")"
  IFS='|' read -r UUID HOST PORT NAME OUTPUT_FILE TYPE VLESS_PATH SECURITY ENCRYPTION TLS SKIP_CERT_VERIFY SNI FLOW FP PBK SID <<< "$parsed"

  # 生成配置
  write_clash_config "$NAME" "$HOST" "$PORT" "$UUID" "$TYPE" "$TLS" "$SKIP_CERT_VERIFY" "$SNI" "$FLOW" "$ENCRYPTION" "$FP" "$PBK" "$SID" "$VLESS_PATH" "$OUTPUT_FILE" "$SECURITY"

  echo -e "${COLOR_GREEN}✅ 生成成功: ${OUTPUT_FILE}${COLOR_RESET}"
  echo -e "配置文件已保存到 ${OUTPUT_FILE}"
  exit 0
}

# 仅当作为主脚本执行时调用 main
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi