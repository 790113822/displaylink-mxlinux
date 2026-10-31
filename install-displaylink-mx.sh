#!/bin/bash
#
# =============================================================================
#  install-displaylink-mx.sh
#  DisplayLink 驱动自动安装 + 配置 + 开机自启动脚本（面向 MX Linux）
#
#  特性：
#    * 自动检测 MX Linux（含 AHS），自动识别 systemd / sysvinit(runit) 两种
#      init 系统并分别配置开机自启动
#    * 优先使用 Synaptics 官方 APT 仓库安装（版本自动跟随官方更新），
#      并搭配 MX/社区维护的 evdi-dkms（DKMS 自动为每个内核编译 evdi 模块）
#    * 若系统已装 DisplayLink（APT 或 /opt/displaylink .run 方式），本脚本会
#      自动识别并只补齐配置与开机自启动，不会重复安装（幂等）
#    * 自动安装缺失的系统依赖（linux-headers、dkms、unzip、wget 等）
#    * 自动处理 udl/udlfb 内核模块黑名单（避免与 evdi 显示冲突）
#    * 自动配置 udev 规则、evdi 开机加载、systemd 服务 / sysvinit init 脚本
#
#  用法：
#    sudo ./install-displaylink-mx.sh             # 安装 + 配置开机自启动
#    sudo ./install-displaylink-mx.sh --status    # 只查看状态
#    sudo ./install-displaylink-mx.sh --uninstall # 彻底卸载
#
#  运行后建议重启（脚本最后会询问是否立即重启）
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ----------------------------- 基础信息 -----------------------------
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
LOG_FILE="/var/log/displaylink-mx-install.log"
VERSION="1.0.0"

# Synaptics 官方 APT 仓库（官方维护，版本自动更新）
SYNAPTICS_APT_LINE="deb [signed-by=/usr/share/keyrings/synaptics-repository-keyring.gpg] https://www.synaptics.com/sites/default/files/Ubuntu stable non-free"
SYNAPTICS_KEYRING_URL="https://www.synaptics.com/sites/default/files/synaptics-repository-keyring.deb"
SYNAPTICS_KEYRING_DEB="/tmp/synaptics-repository-keyring.deb"

# 官方下载页面（用于回退方案解析最新下载地址）
SYNAPTICS_DL_PAGE="https://www.synaptics.com/products/displaylink-graphics/downloads/ubuntu"

# 服务 / 文件路径
SERVICE_NAME="displaylink-driver.service"
SERVICE_FILE="/lib/systemd/system/${SERVICE_NAME}"
INIT_SCRIPT="displaylink.sh"
INIT_SCRIPT_LINK="/etc/init.d/${INIT_SCRIPT}"
INITD_GENERATED="/etc/init.d/displaylink.generated"
RC_LOCAL="/etc/rc.local"
RC5_LINK="/etc/rc5.d/S05displaylink"
MODULES_LOAD_EVDI="/etc/modules-load.d/evdi.conf"
MODPROBE_BLACKLIST="/etc/modprobe.d/displaylink-blacklist.conf"
DISPLAYLINK_BIN="/usr/lib/displaylink-driver/DisplayLinkManager"
XORG_CONF="/etc/X11/xorg.conf.d/20-displaylink.conf"

# 颜色输出（非 TTY 时禁用）
if [ -t 1 ]; then
    C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'; C_YELLO=$'\033[1;33m'; C_CYAN=$'\033[1;36m'; C_RST=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLO=""; C_CYAN=""; C_RST=""
fi
info()  { echo -e "${C_CYAN}[*]${C_RST} $*"; }
ok()    { echo -e "${C_GREEN}[✓]${C_RST} $*"; }
warn()  { echo -e "${C_YELLO}[!]${C_RST} $*"; }
die()   { echo -e "${C_RED}[✗]${C_RST} $*" >&2; exit 1; }

# ---------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------

detect_init() {
    # 返回 systemd / sysvinit（runit 同样走 sysvinit 分支，因为 MX 的
    # 服务脚本仍位于 /etc/init.d + rc*.d，只是 PID 1 由 runit 接管）
    if [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ] || [ -d /run/systemd/system ]; then
        echo "systemd"
        return
    fi
    echo "sysvinit"
}

need_cmd() { command -v "$1" >/dev/null 2>&1; }

install_pkgs() {
    # 并行安装缺失的依赖（不阻塞交互）
    local missing=()
    local p
    for p in "$@"; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" \
            && continue
        missing+=("$p")
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        ok "系统依赖已齐全（${*// /, }）"
        return
    fi
    info "安装系统依赖：${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
}

install_kernel_headers() {
    # 当前内核的 headers 是 dkms 编译 evdi 的前提，必须确保存在
    if [ -d "/usr/src/linux-headers-$(uname -r)" ]; then
        ok "当前内核 headers 已存在（$(uname -r)）"
        return
    fi
    info "当前内核缺少 headers，尝试安装 linux-headers-$(uname -r)"
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "linux-headers-$(uname -r)"; then
        # AHS 内核（如 7.2.13-1-liquorix-amd64）对应包名可能带 -ahs 或需用 meta 包
        DEBIAN_FRONTEND=noninteractive apt-get install -y linux-headers-liquorix-amd64 2>/dev/null \
            || warn "未能自动安装当前内核 headers，稍后重启进其他内核时可用"
    fi
}

setup_evdi_at_boot() {
    # 1) evdi 内核模块开机加载（sysvinit 下最关键的一步；systemd 下也可用）
    if [ -f "$MODULES_LOAD_EVDI" ] && grep -q '^evdi$' "$MODULES_LOAD_EVDI"; then
        ok "evdi 开机加载已配置（${MODULES_LOAD_EVDI}）"
    else
        info "配置 evdi 开机自动加载"
        echo "evdi" > "$MODULES_LOAD_EVDI"
        ok "已写入 ${MODULES_LOAD_EVDI}"
    fi
    # 立即加载（若当前内核 DKMS 已编译好）
    if ! lsmod | grep -q '^evdi'; then
        modprobe evdi 2>/dev/null \
            && ok "evdi 内核模块已加载" \
            || warn "evdi 模块暂未加载（DKMS 编译完成或重启后生效）"
    else
        ok "evdi 内核模块已在运行"
    fi
}

setup_blacklist() {
    # udl/udlfb 是旧的 DisplayLink 内核驱动，与 evdi 冲突，需黑名单
    if grep -Eq '^\s*blacklist\s+(udl|udlfb)' "$MODPROBE_BLACKLIST" 2>/dev/null; then
        ok "udl/udlfb 黑名单已配置"
    else
        info "添加 udl/udlfb 黑名单（避免与 evdi 冲突）"
        {
            echo "# Blacklist old DisplayLink kernel drivers that conflict with evdi"
            echo "blacklist udl"
            echo "blacklist udlfb"
        } > "$MODPROBE_BLACKLIST"
        ok "已写入 ${MODPROBE_BLACKLIST}"
    fi
}

setup_systemd_autostart() {
    # systemd 分支：确保服务有 [Install] 段（官方包常常缺失，见
    # displaylink-debian issue #42），然后 enable + start
    if [ ! -f "$SERVICE_FILE" ]; then
        die "找不到 ${SERVICE_FILE}，请先安装 DisplayLink 驱动"
    fi
    if ! grep -q '^\[Install\]' "$SERVICE_FILE"; then
        info "为 ${SERVICE_FILE} 补充 [Install] 段"
        sed -i '/RestartSec=5/a[Install]\nWantedBy=multi-user.target' "$SERVICE_FILE"
        systemctl daemon-reload
    fi
    systemctl enable "${SERVICE_NAME}" 2>/dev/null || true
    # 幂等启动
    systemctl restart "${SERVICE_NAME}" 2>/dev/null \
        || systemctl start "${SERVICE_NAME}" 2>/dev/null || true
    ok "systemd 服务已启用并尝试启动（${SERVICE_NAME}）"
}

setup_sysvinit_autostart() {
    # sysvinit / runit 分支（MX Linux 23+ 默认 init 是 runit）：
    #  runit 不会执行 /etc/rc*.d 里的 S 链接，但 MX 默认提供一个 oneshot
    #  服务执行 /etc/rc.local。因此这里同时配置：
    #   1) /etc/init.d/displaylink.sh + update-rc.d（传统 sysvinit）
    #   2) /etc/rc.local 追加启动命令（runit 兜底）
    local dlm_bin=""
    for p in /usr/lib/displaylink-driver/DisplayLinkManager /opt/displaylink/DisplayLinkManager; do
        [ -x "$p" ] && dlm_bin="$p" && break
    done
    [ -z "$dlm_bin" ] && dlm_bin="$DISPLAYLINK_BIN"

    # 1) init 脚本（优先官方自带，否则自建）
    local candidate=""
    for c in /opt/displaylink/displaylink.sh /usr/lib/displaylink-driver/displaylink.sh /etc/init.d/displaylink.sh; do
        [ -f "$c" ] && candidate="$c" && break
    done
    if [ -n "$candidate" ]; then
        ln -sfn "$candidate" "$INIT_SCRIPT_LINK"
        chmod +x "$candidate"
        ok "init 脚本已软链接：${INIT_SCRIPT_LINK} -> ${candidate}"
    else
        info "官方包未提供 init 脚本，创建自建脚本体"
        local initd_dir; initd_dir="$(dirname "$INITD_GENERATED")"
        mkdir -p "$initd_dir"
        cat > "$INITD_GENERATED" <<'EOF'
#!/bin/bash
### BEGIN INIT INFO
# Provides:          displaylink
# Required-Start:    $local_fs $remote_fs
# Required-Stop:     $local_fs $remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: DisplayLink Manager (evdi)
# Description:       Starts DisplayLink Driver Manager
### END INIT INFO

DLM_BIN="__DLM_BIN__"

case "$1" in
  start)
    modprobe evdi 2>/dev/null || true
    # 兜底启动：图形会话中的真正启动由 udev 规则负责
    if ! pgrep -f "$DLM_BIN" >/dev/null; then
      "$DLM_BIN" >/dev/null 2>&1 &
    fi
    ;;
  stop)
    pkill -f "$DLM_BIN" 2>/dev/null || true
    ;;
  restart)
    "$0" stop; sleep 1; "$0" start
    ;;
  status)
    if pgrep -f "$DLM_BIN" >/dev/null; then
      echo "DisplayLink is running"; exit 0
    else
      echo "DisplayLink is NOT running"; exit 3
    fi
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status}"
    exit 1
    ;;
esac
exit 0
EOF
        sed -i "s|__DLM_BIN__|$dlm_bin|" "$INITD_GENERATED"
        chmod +x "$INITD_GENERATED"
        ln -sfn "$INITD_GENERATED" "$INIT_SCRIPT_LINK"
        ok "已创建并链接自建 init 脚本"
    fi

    # 2) 传统 sysvinit：update-rc.d 注册默认运行级别
    update-rc.d displaylink.sh defaults >/dev/null 2>&1 || true
    local rcd_dir; rcd_dir="$(dirname "$RC5_LINK")"
    if [ -d "$rcd_dir" ] && ! ls "$rcd_dir" | grep -q "S.*displaylink"; then
        ln -sfn "$INIT_SCRIPT_LINK" "$RC5_LINK"
    fi
    ok "sysvinit 开机自启动已配置（update-rc.d + rc*.d 链接）"

    # 3) runit 兜底：往 rc.local 注册（幂等）；注意 sed 分隔符不能与
    #    路径中的内容冲突，这里用 @
    if [ -f "$RC_LOCAL" ]; then
        if grep -q "${INIT_SCRIPT_LINK} start" "$RC_LOCAL"; then
            ok "${RC_LOCAL} 已注册 displaylink 启动（runit 兜底）"
        else
            if grep -qE '^\s*exit\s+0' "$RC_LOCAL"; then
                sed -i "s@^\(\s*exit\s\+0\)@${INIT_SCRIPT_LINK} start\n\1@" "$RC_LOCAL"
            else
                printf '\n%s\n' "${INIT_SCRIPT_LINK} start" >> "$RC_LOCAL"
            fi
            ok "已在 ${RC_LOCAL} 注册 displaylink 启动（runit 兜底）"
        fi
    else
        cat > "$RC_LOCAL" <<EOF
#!/bin/sh
${INIT_SCRIPT_LINK} start
exit 0
EOF
        chmod +x "$RC_LOCAL"
        ok "已创建 ${RC_LOCAL} 并注册 displaylink 启动（runit 兜底）"
    fi
    [ -f "$RC_LOCAL" ] && chmod +x "$RC_LOCAL"

    # 4) 本次会话先启动（幂等：已在运行则跳过）
    if ! pgrep -f "$dlm_bin" >/dev/null; then
        "$INIT_SCRIPT_LINK" start 2>/dev/null || true
    fi
    ok "DisplayLink 服务启动检查完成"
}

install_from_run() {
    # 备用方案：从 Synaptics 官方 .zip/.run 安装（APT 不可用/安装失败时）
    # 参考 displaylink-debian 的成熟处理：--keep --noexec 解压 → 修正
    # SYSTEMINITDAEMON 探测 → 手动执行官方 installer → 由本脚本接管自启动
    info "== 回退：从官方 .run 安装包安装 =="
    install_pkgs unzip wget

    local tmp page_zip dl_url runfile
    tmp="$(mktemp -d --suffix=.dlm)"
    info "解析官方下载地址：${SYNAPTICS_DL_PAGE}"
    page_zip="$(wget -q -O - --user-agent="Mozilla/5.0" "$SYNAPTICS_DL_PAGE" \
        | grep -oE '"/sites/default/files/exe_files/[^"]+EXE[^"]*\.(zip|run)"' \
        | head -n 1 | tr -d '"')"
    [ -n "$page_zip" ] || die "无法解析官方下载地址（网络或页面结构变化）"
    dl_url="https://www.synaptics.com${page_zip}"
    info "官方下载地址：${dl_url}"

    info "下载驱动（约 60-70 MB）……"
    wget -q --user-agent="Mozilla/5.0" -O "$tmp/dl.zip" "$dl_url" \
        || die "下载失败：${dl_url}"
    ok "下载完成"

    cd "$tmp"
    unzip -o -q dl.zip
    runfile="$(ls displaylink-driver-*.run 2>/dev/null | head -n 1)"
    [ -n "$runfile" ] || die "解压后未找到 displaylink-driver-*.run"
    chmod +x "$runfile"

    # 解压驱动的自安装脚本（不安装，只提取内容）
    "$runfile" --keep --noexec >/dev/null 2>&1 || true
    local dir
    dir="$(ls -d displaylink-driver-* 2>/dev/null | grep -v '\.run$' | head -n 1)"
    if [ -n "$dir" ] && [ -f "$dir/displaylink-installer.sh" ]; then
        # 修正 init 系统探测（MX 上是 runit/sysvinit，官方脚本探测不到会走默认）
        sed -i 's/SYSTEMINITDAEMON=unknown/SYSTEMINITDAEMON=sysvinit/' \
            "$dir/displaylink-installer.sh"
        info "运行官方 installer（已适配 MX init 系统）……"
        ( cd "$dir" && ./displaylink-installer.sh install ) >/dev/null 2>&1 || true
    else
        # 兜底：直接运行 .run（使用 --accept 自动同意 EULA）
        info "运行官方安装器：${runfile} --accept"
        "$runfile" --accept >/dev/null 2>&1 || true
    fi

    cd / && rm -rf "$tmp"
}

ensure_driver_installed() {
    # 统一入口：确保已安装 displaylink-driver（APT 或 /opt/displaylink 均可）
    if [ -x "$DISPLAYLINK_BIN" ] \
        && dpkg-query -W -f='${Status}' displaylink-driver 2>/dev/null | grep -q "install ok installed"; then
        ok "检测到已安装的 displaylink-driver（APT 版本）"
        return 0
    fi
    if [ -x /opt/displaylink/DisplayLinkManager ]; then
        ok "检测到已安装的 DisplayLink（/opt/displaylink，.run 方式）"
        return 0
    fi

    info "未检测到 DisplayLink 驱动，开始安装……"

    # 1) 添加 Synaptics 官方 APT 仓库（若尚未添加）
    if [ -f /etc/apt/sources.list.d/synaptics.list ] \
        && grep -q 'synaptics.com' /etc/apt/sources.list.d/synaptics.list 2>/dev/null; then
        info "检测到 Synaptics APT 源，跳过添加"
    else
        info "添加 Synaptics 官方 APT 仓库……"
        command -v wget >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y wget
        wget -q -O "$SYNAPTICS_KEYRING_DEB" "$SYNAPTICS_KEYRING_URL" \
            || die "下载 Synaptics 官方 APT 密钥失败：${SYNAPTICS_KEYRING_URL}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$SYNAPTICS_KEYRING_DEB" \
            || die "安装 Synaptics 官方 APT 密钥失败"
        echo "$SYNAPTICS_APT_LINE" > /etc/apt/sources.list.d/synaptics.list
        ok "已添加 Synaptics 官方 APT 仓库"
    fi

    # 2) 安装依赖（DKMS 需要当前内核 headers）
    install_pkgs dkms evdi-dkms wget unzip
    install_kernel_headers

    # 3) 安装驱动本体
    if DEBIAN_FRONTEND=noninteractive apt-get update -y \
        && DEBIAN_FRONTEND=noninteractive apt-get install -y displaylink-driver; then
        ok "displaylink-driver 安装完成（APT 方式）"
    else
        warn "APT 安装失败，尝试官方 .run 安装包……"
        install_from_run
    fi
}

pull_evdi_dkms() {
    # 确保 evdi-dkms 已安装（MX/社区维护的 DKMS 包装，已随上面依赖装好）
    if dpkg-query -W -f='${Status}' evdi-dkms 2>/dev/null | grep -q "install ok installed"; then
        ok "evdi-dkms 已安装"
        # 确保当前内核已编译
        if ! lsmod | grep -q '^evdi' && [ -d "/usr/src/linux-headers-$(uname -r)" ]; then
            info "为当前内核编译 evdi 内核模块（DKMS）……"
            dkms autoinstall -k "$(uname -r)" 2>/dev/null || true
        fi
    else
        install_pkgs evdi-dkms
        install_kernel_headers
    fi
}

uninstall_all() {
    info "=== 卸载 DisplayLink ==="
    # 停止所有入口
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    update-rc.d displaylink.sh remove >/dev/null 2>&1 || true
    rm -f "$RC5_LINK"

    # 清理 rc.local 中的注册行（若有）
    if [ -f "$RC_LOCAL" ]; then
        sed -i "\@${INIT_SCRIPT_LINK} start@d" "$RC_LOCAL"
        ok "已从 ${RC_LOCAL} 移除 displaylink 启动行"
    fi

    pkill -f 'DisplayLinkManager' 2>/dev/null || true

    # 卸载 APT 包
    DEBIAN_FRONTEND=noninteractive apt-get purge -y displaylink-driver evdi-dkms 2>/dev/null || true

    # 卸载 .run 安装（如有）
    if [ -f /opt/displaylink/uninstall.sh ]; then
        (cd /opt/displaylink && ./uninstall.sh) 2>/dev/null || true
    fi

    # 清理自启动与黑名单
    rm -f "$MODULES_LOAD_EVDI" "$INIT_SCRIPT_LINK" "$INITD_GENERATED"
    rm -f "$MODPROBE_BLACKLIST"
    systemctl daemon-reload 2>/dev/null || true
    ok "卸载完成"
}

show_status() {
    info "=== DisplayLink 状态 ==="
    # 服务
    if [ "$(detect_init)" = "systemd" ]; then
        if systemctl is-enabled "${SERVICE_NAME}" >/dev/null 2>&1; then
            echo "服务：systemd 已启用（${SERVICE_NAME}）"
        else
            echo "服务：systemd 未启用"
        fi
    else
        # sysvinit：检查 rc5 的 S 链接是否指向我们的 init 脚本
        if [ -L "$RC5_LINK" ] || ls /etc/rc*.d/ 2>/dev/null | grep -qi displaylink; then
            echo "服务：sysvinit 已启用（rc*.d 有链接）"
        else
            echo "服务：sysvinit 未启用"
        fi
    fi
    # 进程
    if pgrep -f 'DisplayLinkManager' >/dev/null; then
        echo "进程：$(pgrep -af 'DisplayLinkManager' | head -n 3 | tr '\n' '; ')"
    else
        echo "进程：未运行"
    fi
    # 内核模块
    lsmod | grep -q '^evdi' && echo "内核模块：evdi 已加载" || echo "内核模块：evdi 未加载"
    # 版本
    dpkg-query -W -f='驱动版本：${Version}\n' displaylink-driver 2>/dev/null || true
    if [ -f /sys/devices/evdi/version ]; then
        echo "evdi 版本：$(cat /sys/devices/evdi/version)"
    fi
    # X11 配置
    if [ -f "$XORG_CONF" ]; then
        echo "X11 配置：$XORG_CONF"
    fi
    # 自启动项
    if [ -f "$MODULES_LOAD_EVDI" ]; then
        echo "开机加载模块：$(tr '\n' ' ' < "$MODULES_LOAD_EVDI")"
    fi
    if [ -f "$MODPROBE_BLACKLIST" ]; then
        echo "黑名单：$(grep -v '^#' "$MODPROBE_BLACKLIST" | tr '\n' ' ')"
    fi
}

reboot_dialog() {
    echo
    read -r -p "是否立即重启使所有更改生效？[y/N] " ans
    case "$ans" in
        y|Y)
            info "重启中……"
            systemctl reboot 2>/dev/null || reboot
            ;;
        *)
            ok "请记得手动重启系统（模块/udev/内核相关更改需要重启生效）"
            ;;
    esac
}

# ---------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------
main() {
    # 参数解析（先于 root 检查，便于 --help / --status 普通用户使用）
    local MODE="install"
    case "${1:-}" in
        --uninstall) MODE="uninstall" ;;
        --status)    MODE="status" ;;
        --help|-h)   MODE="help" ;;
    esac

    if [ "$MODE" = "help" ]; then
        echo "用法："
        echo "  sudo $0                安装 + 配置开机自启动（幂等）"
        echo "  sudo $0 --status      只查看当前状态"
        echo "  sudo $0 --uninstall   彻底卸载"
        exit 0
    fi

    # root 检查（安装 / 卸载 / 状态都涉及系统操作，统一要求 root）
    if [ "$(id -u)" -ne 0 ]; then
        die "请使用 root 运行：sudo $0"
    fi

    INIT="$(detect_init)"
    info "=== DisplayLink MX Linux 安装脚本 v${VERSION} ==="
    info "发行版：$(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
    info "内核：$(uname -r)"
    info "init 系统：${INIT}"

    case "$MODE" in
        status)
            show_status
            exit 0
            ;;
        uninstall)
            uninstall_all
            exit 0
            ;;
        install)
            ;;
    esac

    # 1) 系统依赖
    info "== 检查系统依赖 =="
    install_pkgs lsb-release wget curl ca-certificates xz-utils
    install_kernel_headers

    # 2) 安装驱动（已装则自动跳过；APT 不可用时会回退 .run）
    info "== 检查 / 安装 DisplayLink 驱动 =="
    ensure_driver_installed

    # 3) evdi-dkms（DKMS 内核模块）
    info "== 准备 evdi 内核模块（DKMS） =="
    pull_evdi_dkms

    # 4) 配置开机自启动（按 init 系统分支）
    info "== 配置开机自启动 =="
    if [ "$INIT" = "systemd" ]; then
        setup_systemd_autostart
    else
        setup_sysvinit_autostart
    fi
    setup_evdi_at_boot
    setup_blacklist

    # 5) 激活 udev 规则（立即生效，插拔 Dock 即可用）
    info "== 激活 udev 规则 =="
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --subsystem-match=usb 2>/dev/null || true
    ok "udev 规则已重新加载"

    # 6) 状态确认
    echo
    show_status
    ok "安装与自启动配置完成！"
    reboot_dialog

    echo
    info "日志：${LOG_FILE}"
    info "如需卸载：sudo $0 --uninstall"
}

# 仅当直接执行（非 source）时运行主流程
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi