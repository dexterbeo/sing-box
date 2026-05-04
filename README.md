# Sing-box 多用户与管理脚本

这是一个基于原版 Sing-box 逻辑的一键管理脚本，专为多用户管理场景设计，自编译版本支持 v2ray_api 流量统计。

**交流与反馈**：https://t.me/sb_Carpooling

## 快速开始

```bash
wget -O sb.sh https://raw.githubusercontent.com/Tangfffyx/sing-box/main/sb.sh && bash sb.sh
```
**非root用户：**
```bash
wget -O sb.sh https://raw.githubusercontent.com/Tangfffyx/sing-box/main/sb.sh && sudo bash sb.sh
```

* **快捷命令**：安装完成后，在终端输入 `s` 即可唤出管理菜单。
* **避免冲突**：如果当前系统已安装官方版本的 sing-box，推荐先在菜单中执行“9. 卸载 sing-box”（保留数据），再执行“1. 安装/更新 sing-box”进行环境接管。

---

## 核心功能

### 1. 用户管理
支持多用户独立计费与权限控制：
* 可添加多个用户，并为其分配指定的节点权限。
* 支持设置用户流量限制，总量=上行流量+下行流量+手动校正流量（经sing-box的流量总量，属于服务器的单向流量）。
* 支持自定义流量重置日（如每月特定日期或月底）。
* 支持设置套餐到期日，到期自动停用。
* 支持一键续期、重置流量、补正流量、启用/停用用户。
* **使用入口**：`7. 用户管理`。

### 2. 协议安装
提供主流协议的一键部署：
* **支持的协议**：Reality、AnyTLS、Shadowsocks2022、SOCKS、Trojan、VMess-WS、VLESS-WS、TUIC。
* **使用入口**：`4. 协议管理` → `安装协议`。

### 3. 中转管理
支持本机作为中转机，将流量转发到落地机：
* **全部流量转发至落地机**：选择一个本机入站协议，将该入站的全部流量转发到指定落地机。
* **部分流量转发至落地机**：可按规则只转发 AI 服务、Google、Netflix、Disney+、YouTube、TikTok 或自定义 geosite 网站规则。
* **落地连接方式**：中转机到落地机统一使用 SOCKS 连接；落地机需要提前准备可连接的 SOCKS 服务。
* **多落地机**：部分流量规则可以分别转发到不同落地机，脚本会按落地标识管理。
* **使用入口**：`5. 中转管理`。

### 4. 导出节点配置
自动生成客户端订阅与配置信息：
* 支持一键导出 Clash、Quantumult X、v2rayN、Surge 等格式的节点配置。

### 5. Telegram Bot 管理
支持通过 Telegram 查看用户状态、接收提醒，并进行基础远程管理。

* **两种模式**：
  * **主控节点**：运行 Telegram Bot，集中查看所有已接入 VPS。
  * **普通节点**：定时向主控节点上报本机用户数据，不需要暴露控制端口。
* **普通用户可用功能**：
  * 绑定自己的用户账号。
  * 查看已绑定节点的流量、补正流量、到期时间和状态。
  * 开启或关闭流量/到期提醒。
* **管理员可用功能**：
  * 查看所有接入 VPS 的在线状态、用户数量、预警和到期情况。
  * 查看单个用户的流量、套餐、到期和启用状态。
  * 远程执行启用/停用、续期、修改套餐、重置流量、补正流量、修改到期时间。
* **提醒机制**：
  * 默认流量达到 90% 时提醒。
  * 默认到期前 3 天提醒。
  * 无需打开 Bot，后台上报时会自动触发提醒。
* **维护操作**：菜单中提供 `设置/启动TG Bot`、`更新/重启TG Bot`、`卸载/停止TG Bot`。
* **使用入口**：`7. 用户管理` → `4. Telegram Bot 管理`。

#### 准备 Bot Token 和管理员 TG ID

使用 Telegram Bot 前，需要先准备两个信息：

* **Bot Token**：
  1. 在 Telegram 搜索 `@BotFather`。
  2. 发送 `/newbot`。
  3. 按提示设置 Bot 名称和用户名。
  4. 创建完成后，`@BotFather` 会返回一串 Token，格式类似：`123456789:AA...`。
* **管理员 TG ID**：
  1. 在 Telegram 搜索 `@userinfobot` 或 `@RawDataBot`。
  2. 向它发送任意消息或 `/start`。
  3. 返回信息中的 `Id` / `User ID` 就是管理员 TG ID。
  4. 只填写数字，不要填写用户名或 `@xxx`。

设置完成后，管理员需要先向自己的 Bot 发送一次 `/start`，否则 Bot 可能无法主动发送测试通知。Bot Token 是敏感信息，请勿公开。

### 6. warp分流
支持将指定网站或服务分流到本机 WARP WireProxy SOCKS：
* 依赖 fscarmen WARP 脚本提供的 WireProxy SOCKS。
* 脚本只管理 sing-box 分流规则，不负责安装、启动、停止或卸载 WARP/WireProxy。
* 支持 AI 服务、Google、Netflix、Disney+、YouTube、TikTok 和自定义 geosite 规则。
* **使用入口**：`8. warp分流`。

---

## 其他特色

* **原生兼容性**：
  采用官方 `with_v2ray_api` 编译版本，底层运行逻辑与官方原版完全一致。
  配置文件固定在 `/etc/sing-box/config.json`。
  支持直接使用 Linux 原生命令进行管理与排错（例如：`systemctl status sing-box` 或 `sing-box check -c /etc/sing-box/config.json`）。
  
* **系统时间校准 (Chrony)**：
  系统工具中提供了一键安装并启用 `chrony` 服务的功能。**强烈推荐执行此项**，因为精准的系统时间是保障流量统计准确性以及 Shadowsocks2022 等防重放协议稳定运行的必要条件。

---

## 卸载说明

菜单中的 **`9. 卸载 sing-box`** 是保留数据的运行环境卸载：

* 会停止并移除 sing-box 服务。
* 会标记 TG Bot 为停用。
* 默认保留 `/etc/sing-box`、`/etc/sing-box-manager`、日志、脚本和快捷命令，方便后续重新安装或恢复。

如需彻底清理脚本与相关配置，再手动执行：

```bash
rm -f /root/sb.sh
rm -f /usr/local/bin/s
rm -rf /etc/sing-box-manager
rm -rf /etc/sing-box
rm -rf /var/log/sing-box
rm -f /var/lock/singbox-manager.lock /var/lock/singbox-tg-agent.lock
rm -rf /var/lock/singbox-tg-agent.lock.d
```
