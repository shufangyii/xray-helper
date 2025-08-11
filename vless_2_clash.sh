#!/bin/bash
# VLESS → Clash Verge 配置生成器 (v2.0)
# 改进:
# - 支持从命令行参数读取链接
# - 自动解析URL中的节点名 (#) 作为代理名和文件名
# - 改进URL参数解析，支持URL解码
# - 优化连接测试的反馈信息

set -e

# --- 颜色定义 ---
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

# --- 依赖检查 ---
check_dep() {
    local pkg="$1"
    local bin="$2"
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo -e "${YELLOW}缺少依赖: ${pkg}，请先安装后重试${RESET}"
        exit 1
    fi
}
check_dep sed sed
check_dep curl curl

# --- 获取 VLESS 链接 (改进1: 支持命令行参数) ---
if [ -n "$1" ]; then
    VLESS_URL="$1"
    echo -e "${GREEN}从命令行参数读取 VLESS 链接。${RESET}"
else
    echo -e "${YELLOW}请输入 VLESS 链接:${RESET}"
    read -r VLESS_URL
fi

if [[ ! "$VLESS_URL" =~ ^vless:// ]]; then
    echo -e "${RED}错误: 请输入有效的 VLESS 链接（以 vless:// 开头）${RESET}"
    exit 1
fi

# --- URL 解码函数 (改进2: 新增) ---
url_decode() {
    local url_encoded="${1//+/ }"
    printf '%b' "${url_encoded//%/\\x}"
}

# --- 解析 VLESS 链接 ---
RAW="${VLESS_URL#vless://}"
UUID="${RAW%%@*}"
REMAINDER="${RAW#*@}"
ADDR_PORT="${REMAINDER%%\?*}"
HOST="${ADDR_PORT%%:*}"
PORT="${ADDR_PORT##*:}"

# 先分割 ? 和 #，再分割参数
QUERY_AND_FRAGMENT="${REMAINDER#*?}"
QUERY_STRING="${QUERY_AND_FRAGMENT%%#*}"
FRAGMENT="${QUERY_AND_FRAGMENT#*#}"

# --- 解析节点名称 (自动提取) ---
if [[ "$VLESS_URL" != *"#"* || -z "$FRAGMENT" || "$FRAGMENT" == "$QUERY_AND_FRAGMENT" ]]; then
    NAME="VLESS-Imported"
else
    NAME=$(url_decode "$FRAGMENT")
fi
OUTPUT_FILE="clash-${NAME// /_}.yaml"

# --- 解析 URL 参数 ---
unset PATH_PARAM SECURITY SNI TYPE FLOW FP PBK SID ENCRYPTION
IFS='&' read -ra PARAMS_ARRAY <<< "$QUERY_STRING"
for param in "${PARAMS_ARRAY[@]}"; do
    key="${param%%=*}"
    value="${param#*=}"
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

# --- 设置默认值 ---
TYPE=${TYPE:-tcp}
VLESS_PATH=${PATH_PARAM:-/}
SECURITY=${SECURITY:-reality}
ENCRYPTION=${ENCRYPTION:-none}

if [[ "$SECURITY" == "tls" || "$SECURITY" == "reality" ]]; then
    TLS=true
    SKIP_CERT_VERIFY=false
else
    TLS=false
    SKIP_CERT_VERIFY=true
fi

# --- 生成 Clash 配置文件 ---
cat > "$OUTPUT_FILE" << EOF
proxies:
  - name: "$NAME"
    type: vless
    server: $HOST
    port: $PORT
    uuid: $UUID
    network: $TYPE
    tls: $TLS
    udp: true
    skip-cert-verify: $SKIP_CERT_VERIFY
    servername: ${SNI:-$HOST}
EOF

[[ -n "$FLOW" ]] && echo "    flow: $FLOW" >> "$OUTPUT_FILE"
[[ -n "$ENCRYPTION" ]] && echo "    encryption: $ENCRYPTION" >> "$OUTPUT_FILE"
[[ -n "$FP" ]] && echo "    client-fingerprint: $FP" >> "$OUTPUT_FILE"

if [[ "$SECURITY" == "reality" ]]; then
    {
      echo "    reality-opts:"
      [[ -n "$PBK" ]] && echo "      public-key: $PBK"
      [[ -n "$SID" ]] && echo "      short-id: $SID"
      [[ -n "$FP" ]] && echo "      fingerprint: $FP"
      echo "      spider-x: /"
    } >> "$OUTPUT_FILE"
fi

if [[ "$TYPE" == "ws" ]]; then
    cat >> "$OUTPUT_FILE" << EOF
    ws-opts:
      path: "$VLESS_PATH"
      headers:
        Host: ${SNI:-$HOST}
EOF
fi

echo -e "${GREEN}✅ 生成成功: ${OUTPUT_FILE}${RESET}"
echo -e "TLS: ${YELLOW}${TLS}${RESET}, 跳过证书验证: ${YELLOW}${SKIP_CERT_VERIFY}${RESET}"
