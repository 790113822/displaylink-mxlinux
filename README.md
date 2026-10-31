# DisplayLink 一键安装脚本（MX Linux）

`install-displaylink-mx.sh` 用于在 MX Linux（含 AHS 版本）上自动安装
DisplayLink 驱动（含 evdi 内核模块），并配置**开机自启动**。

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
| `sudo ./install-displaylink-mx.sh` | 安装 + 配置开机自启动（幂等，可重复运行） |
| `sudo ./install-displaylink-mx.sh --status` | 查看当前驱动 / 自启动 / 模块状态 |
| `sudo ./install-displaylink-mx.sh --uninstall` | 彻底卸载并清理自启动配置 |

## 脚本做了什么

1. **自动安装依赖**：`dkms`、`unzip`、`wget`、`ca-certificates` 及当前内核
   的 `linux-headers`（含 AHS 的 liquorix 内核 headers）。
2. **安装驱动**：优先通过 Synaptics **官方 APT 仓库**安装 `displaylink-driver`
   （自动跟随官方更新，版本 6.x）；若 APT 不可用，自动回退到官方 `.run`
   安装包（自动解析最新版下载地址、自动处理 MX 的 `SYSTEMINITDAEMON` 探测问题）。
3. **evdi 内核模块**：通过 `evdi-dkms` + DKMS 自动为当前内核编译，
   并配置 `/etc/modules-load.d/evdi.conf` 让 evdi **开机自动加载**。
4. **开机自启动**（按系统实际 init 自动分支）：
   - **systemd**：修复官方包缺失 `[Install]` 段的问题，然后
     `systemctl enable`。
   - **sysvinit / runit**（MX Linux 默认）：创建 `/etc/init.d/displaylink.sh`
     并 `update-rc.d defaults`，同时在 `/etc/rc.local` 注册兜底启动命令
     （runit 不会执行 rc*.d 的 S 链接，但 MX 会执行 rc.local），
     并启动 `DisplayLinkManager` 服务。
5. **udl/udlfb 黑名单**：将旧的 DisplayLink 内核驱动加入
   `/etc/modprobe.d/displaylink-blacklist.conf`，避免与 evdi 冲突。
6. **udev 规则**：重新加载官方包自带的 `99-displaylink.rules`，
   插拔扩展坞即自动拉起驱动。

## 注意事项

- 需要 root；使用 **bash** 运行（`sudo bash install-displaylink-mx.sh` 亦可）。
- 驱动装好后 `DisplayLinkManager` 默认由 **udev 规则**在插上设备时自动启动，
  脚本注册的开机自启动是兜底，确保重启后 / 拔插后都能正常工作。
- 如果系统里已经装过 DisplayLink（APT 或 /opt/displaylink 方式），脚本会
  自动识别并**只补齐配置与自启动**，不会重复安装。
- 卸载使用 `--uninstall`，会同时清理 `/opt/displaylink`、apt 包、
  init 脚本、rc.local 注册与黑名单。
- 日志：`/var/log/displaylink-mx-install.log`。

## 验证是否成功

```bash
sudo ./install-displaylink-mx.sh --status
# 期望看到：
#   服务：sysvinit 已启用（或 systemd 已启用）
#   进程：...DisplayLinkManager...
#   内核模块：evdi 已加载
lsmod | grep evdi          # 有输出
ls /etc/rc5.d/ | grep dl   # 有 S05displaylink（sysvinit）
```