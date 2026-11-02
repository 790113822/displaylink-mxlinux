# DisplayLink 一键安装脚本（MX Linux）

`install-displaylink-mx.sh` 用于在 MX Linux（含 AHS 版本）上自动安装
DisplayLink 驱动（含 evdi 内核模块），并配置**开机自启动**。

安装来源是 Synaptics 官方 **standalone 安装包（`.run`）**：脚本自动从官方
下载页解析最新版本 → 下载 `.zip` → 解压出 `.run` → 运行官方 installer。
**不再添加 Synaptics APT 仓库**，也不会执行 `apt install displaylink-driver`。

## 快速开始

```bash
# 下载/复制脚本到本地后，赋予执行权限并运行
chmod +x install-displaylink-mx.sh
sudo ./install-displaylink-mx.sh
```

按提示完成后**重启系统**（脚本末尾也会询问）。重启后插上 DisplayLink
扩展坞 / 转接器即可使用。

## 常用命令

| 命令 | 说明 |
| --- | --- |
| `sudo ./install-displaylink-mx.sh` | 下载官方 `.run` 并安装 + 配置开机自启动（幂等，可重复运行） |
| `sudo ./install-displaylink-mx.sh --run-file FILE` | 使用本地 `.zip` / `.run` 安装包（离线安装） |
| `sudo ./install-displaylink-mx.sh --run-url URL` | 指定 `.zip` / `.run` 下载地址 |
| `sudo ./install-displaylink-mx.sh --status` | 查看当前驱动 / 自启动 / 模块状态 |
| `sudo ./install-displaylink-mx.sh --uninstall` | 彻底卸载并清理自启动配置 |

## 脚本做了什么

1. **自动安装依赖**：`dkms`、`build-essential`、`pkg-config`、`libdrm-dev`、
   `libc6-dev`、`mokutil`、`unzip`、`wget`、`curl`、`lsb-release`，以及当前
   内核的 `linux-headers`（含 AHS 的 liquorix 内核 headers）。
2. **下载并运行官方 `.run`**：
   - 从官方下载页解析最新 standalone 安装包（当前页面形态：下载页列出各
     版本子页面，例如 `.../displaylink-usb-graphics-software-ubuntu-64`，
     子页面里给出 `...exe_files/<日期>/...-EXE.zip`）；
   - 也可用 `--run-file`（本地 `.zip` / `.run`）或 `--run-url`（指定地址）
     完全绕过网页解析，便于离线安装或页面结构变化时使用；
   - 用 `--keep --noexec --nox11` 解压 `.run`：只解压不执行，并避免
     makeself 在“stdout 不是终端”时尝试弹出图形终端（否则解压会静默失败）；
   - **改写官方 installer，强制走 standalone 分支**：6.x 的 installer 在
     Debian 系上会询问 `Do you want to install with apt?`（默认 Y 会改用
     Synaptics APT 仓库），脚本把该判断改掉，确保安装的就是 `.run`；
   - 通过 `SYSTEMINITDAEMON=systemd|runit|upstart` 告诉官方 installer 正确的
     init 类型（否则在 sysvinit 上它会直接报错退出），并传 `noreboot` 参数
     避免它自行重启。
3. **evdi 内核模块**：官方 `.run` 自带 evdi 源码，安装时由 DKMS 编译安装；
   若模块缺失，则回退安装发行版（MX / Debian 仓库，非 Synaptics 仓库）的
   `evdi-dkms`。同时写入 `/etc/modules-load.d/evdi.conf`，让 evdi
   **开机自动加载**。
4. **开机自启动**（按系统实际 init 自动分支）：
   - **systemd**：官方 installer 写入的 `displaylink-driver.service` 没有
     `[Install]` 段，脚本补上后 `systemctl enable`。
   - **runit**（MX Linux 23+ 默认）：官方 `.run` 会创建
     `/etc/runit/sv/displaylink-driver` 服务，但默认带 `down` 标记（只在插拔
     设备时由 udev 执行 `sv up`）；脚本会把它注册到 runsvdir 的服务目录、
     移除 `down` 标记并 `sv up`，从而实现开机自启动。
   - **sysvinit**（或无可用 runit 服务时）：创建
     `/etc/init.d/displaylink.sh` 并 `update-rc.d defaults`，同时在
     `/etc/rc.local` 注册兜底启动命令（runit 不会执行 rc*.d，但 MX 会执行
     rc.local）。
5. **udl/udlfb 黑名单**：将旧的 DisplayLink 内核驱动加入
   `/etc/modprobe.d/displaylink-blacklist.conf`，避免与 evdi 冲突。
6. **udev 规则**：重新加载官方 installer 写入的 `99-displaylink.rules`，
   插拔扩展坞即自动拉起驱动。

## 注意事项

- 需要 root；使用 **bash** 运行（`sudo bash install-displaylink-mx.sh` 亦可）。
- 若系统之前通过 **APT 方式**（Synaptics 仓库）装过 `displaylink-driver`，
  脚本会先 `apt purge` 它并删除 `sources.list.d/synaptics.list`，再安装
  `.run` 版本——两种方式共存会产生重复的 udev 规则与服务。
- 日志：
  - 本脚本：`/var/log/displaylink-mx-install.log`
  - 官方 installer：`/var/log/displaylink/displaylink_installer.log`
- 驱动装好后 `DisplayLinkManager` 默认由 **udev 规则**在插上设备时自动启动，
  脚本注册的开机自启动是兜底，确保重启后 / 拔插后都能正常工作。
- 卸载使用 `--uninstall`：先调用官方卸载器，再兜底清理 `/opt/displaylink`、
  udev 规则、systemd / runit / init.d 自启动项、rc.local 注册与黑名单。
  若脚本曾回退安装过 `evdi-dkms`，可用 `sudo apt purge evdi-dkms` 一并移除。
- 如果官方下载页结构再次变化导致无法解析下载地址，可用 `--run-url` 直接指定
  下载链接，或 `--run-file` 使用已下载的安装包（脚本会优先使用显式指定的
  地址 / 文件）。

## 验证是否成功

```bash
sudo ./install-displaylink-mx.sh --status
# 期望看到：
#   服务：systemd 已启用 / runit 已启用（开机自启动）/ sysvinit 已启用
#   进程：...DisplayLinkManager...
#   驱动版本：DisplayLinkManager v6.x.x (...)（.run 方式）
#   内核模块：evdi 已加载

lsmod | grep evdi                  # 有输出
sv status displaylink-driver       # runit 下可查看服务状态
```
