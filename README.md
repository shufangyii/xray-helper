# Xray Helper Scripts

一组用于在 Ubuntu 服务器上快速部署 Xray 代理服务的 Shell 脚本。

## 脚本说明

### `setup_xray.sh`

**推荐使用**

该脚本用于自动化安装和配置 **Xray (VLESS + TCP + REALITY)** 服务。这是一种先进的代理方案，具有以下特点：

-   **高伪装性**: 使用 [REALITY](https://github.com/XTLS/Xray-core/discussions/1509) 技术，消除 TLS 指纹，有效抵抗主动探测。
-   **无需域名**: 直接使用服务器 IP，简化了部署流程。
-   **WARP 出站 (可选)**: 可以将服务器的所有出站流量通过 Cloudflare WARP 路由，解锁流媒体或隐藏服务器真实 IP。
-   **自动开启 BBR**: 优化 TCP 连接，提升网络速度。
-   **支持命令行管理**: 提供 `status`, `uninstall`, `help` 等参数，方便管理。

**适用系统**: Ubuntu 20.04

#### 使用方法

1.  下载脚本：
    ```bash
    wget https://raw.githubusercontent.com/your_username/xray-helper/main/setup_xray.sh
    chmod +x setup_xray.sh
    ```
2.  运行交互式安装：
    ```bash
    sudo ./setup_xray.sh
    ```
3.  根据提示输入监听端口、伪装域名等信息即可。

### `vless_2_clash.sh`

一个辅助工具，用于将 VLESS 链接转换为 [Clash Verge](https://github.com/zzzgydi/clash-verge) 客户端兼容的 YAML 配置文件。

#### 使用方法

1.  直接运行脚本并粘贴 VLESS 链接：
    ```bash
    ./vless_2_clash.sh
    ```
2.  或者将 VLESS 链接作为命令行参数传入：
    ```bash
    ./vless_2_clash.sh "vless://..."
    ```
-   脚本会自动从链接的 `#` 后面提取节点名，并生成名为 `clash-节点名.yaml` 的文件。

---

## 草稿脚本 (`/drafts`)

`drafts` 目录包含一些旧版本或实验性的脚本，不建议在生产环境中使用。

-   `setup_rellity_1.0.sh`: `setup_xray.sh` 的早期版本。
-   `setup_vpn_2.0.sh` / `setup_vpn_3.0.sh`: 用于部署传统的 **VLESS + WebSocket + TLS + Nginx** 方案的脚本。该方案需要一个域名，并通常与 Cloudflare CDN 配合使用。

