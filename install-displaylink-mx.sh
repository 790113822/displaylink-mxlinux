#!/bin/bash
#
# =============================================================================
#  install-displaylink-mx.sh
#  DisplayLink 驱动自动安装 + 配置 + 开机自启动脚本（面向 MX Linux）
#
#  特性：
#    * 自动检测 MX Linux（含 AHS），自动识别 systemd / runit / sysvinit 三种
#      init 系统并分别配置开机自启动
#    * 使用 Synaptics 官方 standalone 安装包（.run）：自动从官方下载页解析
#      最新版本 → 下载 .zip → 解压 .run → 运行官方 installer
#      （不再添加 / 使用 Synaptics APT 仓库）
#    * 支持离线安装：--run-file 指定本地 .zip / .run 安装包；
#      --run-url 指定 .zip / .run 下载地址
#    * 若系统已装 DisplayLink（.run 方式），本脚本会识别并只补齐配置与
#      开机自启动，不会重复安装（幂等）；旧的 APT 版本会先卸载以避免冲突
#    * 自动安装缺失的系统依赖（linux-headers、dkms、unzip、wget 等）
#    * 自动处理 udl/udlfb 内核模块黑名单（避免与 evdi 显示冲突）
#    * 自动配置 udev 规则、evdi 开机加载、systemd 服务 / runit 服务 /
#      sysvinit init 脚本
#
#  用法：
#    sudo ./install-displaylink-mx.sh                  # 下载 .run 并安装 + 开机自启动
#    sudo ./install-displaylink-mx.sh --run-file F.run # 使用本地安装包（离线安装）
#    sudo ./install-displaylink-mx.sh --run-url URL    # 指定 .zip / .run 下载地址
#    sudo ./install-displaylink-mx.sh --status         # 只查看状态
#    sudo ./install-displaylink-mx.sh --uninstall      # 彻底卸载
#
#  运行后建议重启（脚本最后会询问是否立即重启）
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ----------------------------- 基础信息 -----------------------------
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
LOG_FILE="/var/log/displaylink-mx-install.log"
VERSION="1.1.0"

# Synaptics 官方下载页（standalone 安装包，含最新 .zip/.run 下载地址）
DISPLAYLINK_SITE="https://www.synaptics.com"
DISPLAYLINK_DL_PAGE="${DISPLAYLINK_SITE}/products/displaylink-graphics/downloads/ubuntu"
# 可选：直接指定安装包下载地址（--run-url 或环境变量 DISPLAYLINK_DOWNLOAD_URL）
DISPLAYLINK_DOWNLOAD_URL="${DISPLAYLINK_DOWNLOAD_URL:-}"
# 可选：本地安装包路径（--run-file）
RUN_FILE_LOCAL=""
# 临时工作目录（EXIT trap 负责清理）
TMP_WORK_DIR=""

# 旧版 APT 方式遗留的仓库配置（仅用于识别与清理，本脚本不再添加）
SYNAPTICS_APT_LIST="/etc/apt/sources.list.d/synaptics.list"
SYNAPTICS_KEYRING="/usr/share/keyrings/synaptics-repository-keyring.gpg"

# 服务 / 文件路径
SERVICE_NAME="displaylink-driver.service"
SERVICE_BASE="displaylink-driver"
SERVICE_FILE="/usr/lib/systemd/system/${SERVICE_NAME}"
SERVICE_FILE_LEGACY="/lib/systemd/system/${SERVICE_NAME}"
INIT_SCRIPT="displaylink.sh"
INIT_SCRIPT_LINK="/etc/init.d/${INIT_SCRIPT}"
INITD_GENERATED="/etc/init.d/displaylink.generated"
RC_LOCAL="/etc/rc.local"
RC5_LINK="/etc/rc5.d/S05displaylink"
MODULES_LOAD_EVDI="/etc/modules-load.d/evdi.conf"
MODPROBE_BLACKLIST="/etc/modprobe.d/displaylink-blacklist.conf"
DISPLAYLINK_BIN="/opt/displaylink/DisplayLinkManager"
DISPLAYLINK_BIN_APT="/usr/lib/displaylink-driver/DisplayLinkManager"
UDEV_RULE_MAIN="/usr/lib/udev/rules.d/99-displaylink.rules"
UDEV_RULE_LEGACY="/etc/udev/rules.d/99-displaylink.rules"
XORG_CONF="/etc/X11/xorg.conf.d/20-displaylink.conf"
STATE_DIR="/var/lib/displaylink-mx"
DRIVER_VERSION_FILE="${STATE_DIR}/driver-version"

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
    # 返回 systemd / runit / sysvinit
    local pid1 init_exe
    pid1="$(ps -p 1 -o comm= 2>/dev/null || true)"
    case "$pid1" in
        systemd)                   echo "systemd"; return ;;
        runit|runit-init|runsvdir) echo "runit";   return ;;
    esac
    init_exe="$(readlink -f /proc/1/exe 2>/dev/null || true)"
    case "$init_exe" in
        *runit*) echo "runit"; return ;;
    esac
    # MX 的 sysvinit 模式：PID 1 仍是 /sbin/init（sysvinit）
    if [ -d /run/systemd/system ]; then
        echo "systemd"
        return
    fi
    echo "sysvinit"
}

installer_init_daemon() {
    # 官方 installer 只接受 upstart / systemd / runit 三种取值
    case "${1:-sysvinit}" in
        systemd) echo "systemd" ;;
        runit)   echo "runit" ;;
        *)       echo "upstart" ;;
    esac
}

need_cmd() { command -v "$1" >/dev/null 2>&1; }

http_get() {
    # 抓取网页内容（优先 curl）
    local url="$1"
    if need_cmd curl; then
        curl -fsSL --connect-timeout 20 --max-time 90 -A "Mozilla/5.0" "$url"
    else
        wget -q -O - --timeout=90 --tries=2 --user-agent="Mozilla/5.0" "$url"
    fi
}

http_download() {
    local url="$1" out="$2"
    if need_cmd curl; then
        curl -fSL --retry 3 --connect-timeout 20 -A "Mozilla/5.0" -o "$out" "$url"
    else
        wget -O "$out" --tries=3 --timeout=60 --user-agent="Mozilla/5.0" "$url"
    fi
}

install_pkgs() {
    # 安装缺失的系统依赖（已安装的自动跳过）
    local missing=()
    local p list=""
    for p in "$@"; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" \
            && continue
        missing+=("$p")
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        for p in "$@"; do list+="${p}, "; done
        ok "系统依赖已齐全（${list%, }）"
        return
    fi
    for p in "${missing[@]}"; do list+="${p}, "; done
    info "安装系统依赖：${list%, }"

    DEBIAN_FRONTEND=noninteractive apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
}

install_kernel_headers() {
    # 当前内核 headers 是 DKMS 编译 evdi 的前提，官方 installer 也会检查
    # /lib/modules/$(uname -r)/build 是否存在
    local kver
    kver="$(uname -r)"
    if [ -d "/lib/modules/${kver}/build" ] || [ -d "/usr/src/linux-headers-${kver}" ]; then
        ok "当前内核 headers 已存在（${kver}）"
        return
    fi

    info "当前内核缺少 headers，尝试安装 linux-headers-${kver}"
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "linux-headers-${kver}"; then
        # AHS 内核（如 liquorix）对应包名可能不同，退回 meta 包
        DEBIAN_FRONTEND=noninteractive apt-get install -y linux-headers-liquorix-amd64 2>/dev/null \
            || warn "未能自动安装当前内核 headers，稍后重启进其他内核时可用"
    fi
}

setup_evdi_at_boot() {
    # 1) evdi 内核模块开机加载（sysvinit / runit 下最关键的一步；systemd 下也可用）
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
    # systemd 分支：官方 .run 安装的 displaylink-driver.service 没有 [Install]
    # 段（见 service-installer.sh），补上后才能 enable
    local service_file="$SERVICE_FILE"
    if [ ! -f "$service_file" ] && [ -f "$SERVICE_FILE_LEGACY" ]; then
        service_file="$SERVICE_FILE_LEGACY"
    fi
    if [ ! -f "$service_file" ]; then
        die "找不到 ${SERVICE_FILE}，请先安装 DisplayLink 驱动"
    fi

    if ! grep -q '^\[Install\]' "$service_file"; then
        info "为 ${service_file} 补充 [Install] 段"
        printf '\n[Install]\nWantedBy=multi-user.target\n' >> "$service_file"
        systemctl daemon-reload
    fi

    systemctl enable "${SERVICE_NAME}" 2>/dev/null || true
    # 幂等启动
    systemctl restart "${SERVICE_NAME}" 2>/dev/null \
        || systemctl start "${SERVICE_NAME}" 2>/dev/null || true
    ok "systemd 服务已启用并尝试启动（${SERVICE_NAME}）"
}

setup_runit_autostart() {
    # runit 分支（MX Linux 23+ 默认 init）：官方 .run 会创建
    # /etc/runit/sv/displaylink-driver 服务，但默认带 down 标记（只在 udev
    # 检测到设备时由 /opt/displaylink/udev.sh 执行 sv up）。要实现开机自启动，
    # 需要把服务注册到 runsvdir 的服务目录并去掉 down 标记。
    local svdir="" d
    for d in /etc/runit/sv/${SERVICE_BASE} /etc/sv/${SERVICE_BASE}; do
        if [ -d "$d" ]; then
            svdir="$d"
            break
        fi
    done
    [ -n "$svdir" ] || return 1

    local service_dir=""
    service_dir="$(pgrep -a runsvdir 2>/dev/null \
        | sed -nE 's~^.*-P[[:space:]]+([^[:space:]]+).*$~\1~p' \
        | head -n 1 || true)"
    if [ -z "$service_dir" ] || [ ! -d "$service_dir" ]; then
        service_dir=""
        for d in /etc/service /var/service /service /run/runit/service /run/service; do
            if [ -d "$d" ]; then
                service_dir="$d"
                break
            fi
        done
    fi
    if [ -z "$service_dir" ]; then
        warn "未找到 runsvdir 服务目录，无法注册 runit 服务"
        return 1
    fi

    if [ -e "${service_dir}/${SERVICE_BASE}" ]; then
        ok "runit 服务已注册：${service_dir}/${SERVICE_BASE}"
    else
        ln -sfn "$svdir" "${service_dir}/${SERVICE_BASE}"
        ok "已把 runit 服务注册到 ${service_dir}/${SERVICE_BASE}"
    fi

    rm -f "${svdir}/down"
    ok "已移除 ${svdir}/down（runit 开机自启动）"

    if need_cmd sv; then
        # sv up 同时用于校验服务是否真的被 runsvdir 监管
        if sv up "${SERVICE_BASE}" >/dev/null 2>&1; then
            ok "runit 服务已启动（sv up ${SERVICE_BASE}）"
        else
            warn "sv up ${SERVICE_BASE} 未成功，改用 init 脚本 / rc.local 兜底"
            return 1
        fi
    fi
    return 0
}

setup_sysvinit_autostart() {
    # runit（MX 23+ 默认）优先使用官方 .run 提供的 runit 服务
    if [ "$INIT" = "runit" ] && setup_runit_autostart; then
        return 0
    fi

    # sysvinit / runit 兜底分支：
    #  runit 不会执行 /etc/rc*.d 里的 S 链接，但 MX 默认提供一个 oneshot
    #  服务执行 /etc/rc.local。因此这里同时配置：
    #   1) /etc/init.d/displaylink.sh + update-rc.d（传统 sysvinit）
    #   2) /etc/rc.local 追加启动命令（runit 兜底）
    local dlm_bin="" p
    for p in "$DISPLAYLINK_BIN" "$DISPLAYLINK_BIN_APT"; do
        [ -x "$p" ] && dlm_bin="$p" && break
    done
    [ -z "$dlm_bin" ] && dlm_bin="$DISPLAYLINK_BIN"

    # 1) init 脚本（优先官方自带，否则自建）
    local candidate=""
    for p in /opt/displaylink/displaylink.sh /usr/lib/displaylink-driver/displaylink.sh /etc/init.d/displaylink.sh; do
        [ -f "$p" ] && candidate="$p" && break
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

resolve_download_url() {
    # 解析官方最新 standalone 安装包地址（.zip / .run）
    #
    # 页面结构（2026 年现状）：
    #   https://www.synaptics.com/products/displaylink-graphics/downloads/ubuntu
    #     → /products/displaylink-usb-graphics-software-ubuntu-64?filetype=exe
    #       → /sites/default/files/exe_files/<YYYY-MM>/...-EXE.zip
    # 旧版页面则直接在下载页里给出 exe_files 链接，因此两种都兼容。
    local base="$DISPLAYLINK_SITE"
    local html verpage page_slug="" page exe_url

    # 0) 显式指定（--run-url / 环境变量 DISPLAYLINK_DOWNLOAD_URL）优先
    if [ -n "$DISPLAYLINK_DOWNLOAD_URL" ]; then
        echo "$DISPLAYLINK_DOWNLOAD_URL"
        return 0
    fi

    html="$(http_get "$DISPLAYLINK_DL_PAGE")" || return 1

    # 1) 页面里直接给出 exe 包（旧版页面布局）
    exe_url="$(grep -oE '/sites/default/files/exe_files/[^"]+EXE[^"]*\.(zip|run)' <<< "$html" \
        | head -n 1 || true)"
    if [ -n "$exe_url" ]; then
        echo "${base}${exe_url}"
        return 0
    fi

    # 2) 新版页面布局：主页面按“从新到旧”列出各版本子页面，按顺序尝试，
    #    取第一个能解析出 exe 包的版本页（注意：版本号后缀如 64 / 611 不能
    #    用数值大小比较，611 是 6.1.1）
    while IFS= read -r page_slug; do
        [ -n "$page_slug" ] || continue
        verpage="${base}/products/displaylink-usb-graphics-software-ubuntu-${page_slug}?filetype=exe"
        page="$(http_get "$verpage" 2>/dev/null || true)"
        exe_url="$(grep -oE '/sites/default/files/exe_files/[^"]+EXE[^"]*\.(zip|run)' <<< "$page" \
            | head -n 1 || true)"
        if [ -n "$exe_url" ]; then
            echo "${base}${exe_url}"
            return 0
        fi
    done < <(grep -oE 'displaylink-usb-graphics-software-ubuntu-[0-9]+' <<< "$html" \
        | sed 's/.*-ubuntu-//' | awk '!seen[$0]++')

    return 1
}

install_from_run() {
    info "== 从官方 standalone 安装包（.run）安装 DisplayLink =="

    # 官方 installer 会检查这些依赖，并可能弹出 apt 交互询问；
    # 预先装好可以保证安装过程全自动
    if ! install_pkgs wget curl ca-certificates unzip lsb-release dkms build-essential \
                     pkg-config libdrm-dev libc6-dev coreutils mokutil; then
        die "系统依赖安装失败，请先修复 apt 源（apt update）后重试"
    fi
    install_kernel_headers

    local tmp workdir archive=""
    tmp="$(mktemp -d --suffix=.dlm)"
    TMP_WORK_DIR="$tmp"
    trap 'if [ -n "${TMP_WORK_DIR:-}" ]; then rm -rf "$TMP_WORK_DIR"; fi' EXIT
    workdir="${tmp}/extract"
    mkdir -p "$workdir"

    if [ -n "$RUN_FILE_LOCAL" ]; then
        [ -f "$RUN_FILE_LOCAL" ] || die "指定的安装包不存在：${RUN_FILE_LOCAL}"
        archive="$RUN_FILE_LOCAL"
        info "使用本地安装包：${archive}"
    else
        local url
        url="$(resolve_download_url)" \
            || die "无法解析官方下载地址（网络问题或页面结构变化），可用 --run-url / --run-file 指定"
        info "官方下载地址：${url}"
        case "$url" in
            *.zip|*.ZIP) archive="${tmp}/download.zip" ;;
            *)           archive="${tmp}/download.run" ;;
        esac
        info "下载安装包（约 20-70 MB）……"
        http_download "$url" "$archive" || die "下载失败：${url}"
        ok "下载完成（$(du -h "$archive" | awk '{print $1}')）"
    fi

    case "$archive" in
        *.zip|*.ZIP)
            info "解压 .zip 安装包"
            unzip -o -q "$archive" -d "$workdir" || die "解压失败：${archive}"
            ;;
        *)
            cp -f "$archive" "$workdir/" || die "复制安装包失败：${archive}"
            ;;
    esac

    local runfile
    runfile="$(find "$workdir" -maxdepth 3 -type f -name 'displaylink-driver-*.run' -print -quit)"
    [ -n "$runfile" ] || die "安装包内未找到 displaylink-driver-*.run"
    chmod +x "$runfile"
    ok "安装包：$(basename "$runfile")"

    # --keep --noexec：只解压不执行，便于先做 MX 适配再运行官方 installer
    # --nox11：stdout 不是 TTY（如脚本里重定向日志）时，makeself 默认会尝试
    #          打开图形终端重新执行，这里必须禁用
    local runbase runbasedir
    local -a run_args=(--keep --noexec)
    runbase="$(basename "$runfile")"
    runbasedir="$(dirname "$runfile")"
    if grep -qa -- '--nox11' "$runfile"; then
        run_args+=(--nox11)
    fi
    # --accept：老版本 .run 解压前会要求同意 EULA，自动接受可避免卡住
    if grep -qa -- '--accept' "$runfile"; then
        run_args+=(--accept)
    fi
    ( cd "$runbasedir" && ./"$runbase" "${run_args[@]}" ) >/dev/null 2>&1 || true

    local installer
    installer="$(find "$workdir" -maxdepth 4 -type f -name 'displaylink-installer.sh' -print -quit)"
    [ -n "$installer" ] || die "未能从 .run 中提取 displaylink-installer.sh"
    chmod +x "$installer"
    ok "已提取官方安装器"

    local init_daemon
    init_daemon="$(installer_init_daemon "$INIT")"

    # 6.x 的官方 installer 在 Debian 系上会询问 “Do you want to install
    # with apt?”，默认回答 Y 会走 Synaptics APT 仓库。这里直接改掉该判断，
    # 强制走 standalone（.run）安装路径。
    if grep -q 'prompt_yes_no "Do you want to install with apt?"' "$installer"; then
        sed -i 's#if program_exists apt && prompt_yes_no "Do you want to install with apt?"; then#if false; then#' "$installer"
        ok "已强制使用 standalone（.run）安装路径（跳过官方 apt 方式）"
    fi

    # 官方 installer 的交互问题一律回答 n（不使用 apt / 不立即重启）；
    # 新版支持 noreboot 参数，老版本用应答兜底
    local -a args=(install)
    local -a answers=(n)
    if grep -q 'noreboot)' "$installer"; then
        args+=(noreboot)
    else
        answers+=(n)
    fi

    info "运行官方安装器（init=${init_daemon}，日志：${LOG_FILE}）……"
    local rc=0
    (
        cd "$(dirname "$installer")" \
            && printf '%s\n' "${answers[@]}" \
            | SYSTEMINITDAEMON="$init_daemon" ./displaylink-installer.sh "${args[@]}"
    ) 2>&1 | tee -a "$LOG_FILE" || rc=$?

    if [ -x "$DISPLAYLINK_BIN" ]; then
        local dlm_ver
        dlm_ver="$("$DISPLAYLINK_BIN" -version 2>/dev/null | head -n 1 || true)"
        mkdir -p "$STATE_DIR"
        printf '%s\n' "${dlm_ver:-unknown}" > "$DRIVER_VERSION_FILE"
        [ "$rc" -eq 0 ] || warn "官方安装器返回码 ${rc}，请检查日志：${LOG_FILE}"
        ok "DisplayLink 安装完成${dlm_ver:+（${dlm_ver}）}"
    else
        warn "官方安装器未生成 ${DISPLAYLINK_BIN}（返回码 ${rc}）"
        warn "日志：${LOG_FILE}"
        die "DisplayLink 安装失败"
    fi

    rm -rf "$tmp"
    TMP_WORK_DIR=""
}

ensure_driver_installed() {
    # 统一入口：确保已安装 DisplayLink（.run 方式优先）
    if [ -x "$DISPLAYLINK_BIN" ]; then
        local dlm_ver
        dlm_ver="$("$DISPLAYLINK_BIN" -version 2>/dev/null | head -n 1 || true)"
        if [ -n "$dlm_ver" ]; then
            mkdir -p "$STATE_DIR"
            printf '%s\n' "$dlm_ver" > "$DRIVER_VERSION_FILE"
        fi
        ok "检测到已安装的 DisplayLink（.run 方式：${DISPLAYLINK_BIN}）"
        return 0
    fi

    # 旧的 APT 安装方式会与本脚本的 .run 方式冲突（重复的 udev 规则/服务），先卸载
    if dpkg-query -W -f='${Status}' displaylink-driver 2>/dev/null | grep -q "install ok installed"; then
        warn "检测到旧的 APT 版本 displaylink-driver，与 .run 方式冲突，先卸载"
        DEBIAN_FRONTEND=noninteractive apt-get purge -y displaylink-driver 2>/dev/null || true
        rm -f "$SYNAPTICS_APT_LIST" "$SYNAPTICS_KEYRING"
        ok "已移除旧 APT 版本与 Synaptics APT 仓库配置"
    fi

    info "未检测到 DisplayLink 驱动，开始下载并运行官方 .run 安装包……"
    install_from_run
}

pull_evdi_dkms() {
    # 官方 .run 安装包自带 evdi 源码，安装时会用 DKMS 编译并安装
    if modinfo evdi >/dev/null 2>&1; then
        ok "evdi 内核模块已就绪（$(modinfo -F version evdi 2>/dev/null || echo '来自官方 .run')）"
        return 0
    fi

    # 回退：使用发行版（MX/Debian 仓库，非 Synaptics 仓库）的 evdi-dkms
    warn "未检测到 evdi 内核模块，尝试安装发行版的 evdi-dkms 作为回退"
    if ! install_pkgs dkms evdi-dkms; then
        warn "发行版仓库未提供 evdi-dkms（或安装失败），重启后重新运行本脚本即可"
        return 0
    fi
    install_kernel_headers
    dkms autoinstall -k "$(uname -r)" 2>/dev/null || true
    if modinfo evdi >/dev/null 2>&1; then
        ok "evdi 内核模块已就绪（evdi-dkms）"
    else
        warn "evdi 仍不可用：若刚更新过内核，重启后重新运行本脚本即可"
    fi
}

uninstall_all() {
    info "=== 卸载 DisplayLink ==="
    local init_daemon
    init_daemon="$(installer_init_daemon "$INIT")"

    # 1) 官方卸载器（.run 方式）：停服务、移除 evdi DKMS、udev 规则等
    if [ -x /opt/displaylink/displaylink-installer.sh ]; then
        info "运行官方卸载器（/opt/displaylink/displaylink-installer.sh）"
        ( SYSTEMINITDAEMON="$init_daemon" /opt/displaylink/displaylink-installer.sh uninstall ) \
            >> "$LOG_FILE" 2>&1 || warn "官方卸载器返回非零状态，继续执行兜底清理"
    fi

    # 2) 停止所有入口
    systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
    if need_cmd sv; then
        sv down "${SERVICE_BASE}" 2>/dev/null || true
    fi
    update-rc.d displaylink.sh remove >/dev/null 2>&1 || true
    rm -f "$RC5_LINK"
    pkill -f 'DisplayLinkManager' 2>/dev/null || true

    # 清理 rc.local 中的注册行（若有）
    if [ -f "$RC_LOCAL" ]; then
        sed -i "\@${INIT_SCRIPT_LINK} start@d" "$RC_LOCAL"
        ok "已从 ${RC_LOCAL} 移除 displaylink 启动行"
    fi

    # 3) 兼容历史 APT 安装与 Synaptics APT 仓库残留
    rm -f "$SYNAPTICS_APT_LIST" "$SYNAPTICS_KEYRING" /tmp/synaptics-repository-keyring.deb
    if dpkg-query -W -f='${Status}' displaylink-driver 2>/dev/null | grep -q "install ok installed"; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y displaylink-driver 2>/dev/null || true
    fi

    # 4) 兜底清理官方安装器写入的文件
    rm -rf /opt/displaylink
    rm -f /usr/bin/displaylink-installer /usr/bin/DLSupportTool.sh
    rm -f "$UDEV_RULE_MAIN" "$UDEV_RULE_LEGACY"
    rm -f "$SERVICE_FILE" "$SERVICE_FILE_LEGACY" /lib/systemd/system-sleep/displaylink.sh
    rm -rf "/etc/runit/sv/${SERVICE_BASE}" "/etc/sv/${SERVICE_BASE}"
    rm -f "/etc/service/${SERVICE_BASE}" "/var/service/${SERVICE_BASE}" "/service/${SERVICE_BASE}"
    rm -rf /var/log/displaylink

    # 5) 清理自启动与黑名单
    rm -f "$MODULES_LOAD_EVDI" "$INIT_SCRIPT_LINK" "$INITD_GENERATED" "$MODPROBE_BLACKLIST"
    rm -rf "$STATE_DIR"
    systemctl daemon-reload 2>/dev/null || true
    udevadm control --reload-rules 2>/dev/null || true
    ok "卸载完成（若本脚本曾回退安装 evdi-dkms，可用 apt purge evdi-dkms 移除）"
}

show_status() {
    info "=== DisplayLink 状态 ==="
    local init_kind
    init_kind="$(detect_init)"

    # 服务
    case "$init_kind" in
        systemd)
            if systemctl is-enabled "${SERVICE_NAME}" >/dev/null 2>&1; then
                echo "服务：systemd 已启用（${SERVICE_NAME}）"
            else
                echo "服务：systemd 未启用"
            fi
            ;;
        runit)
            local svdir="" d
            for d in /etc/runit/sv/${SERVICE_BASE} /etc/sv/${SERVICE_BASE}; do
                if [ -d "$d" ]; then
                    svdir="$d"
                    break
                fi
            done
            if [ -n "$svdir" ]; then
                if [ -e "${svdir}/down" ]; then
                    echo "服务：runit 已注册（带 down 标记，插拔设备时由 udev 启动）"
                else
                    echo "服务：runit 已启用（开机自启动）"
                fi
            elif grep -qs "${INIT_SCRIPT_LINK} start" "$RC_LOCAL" || [ -L "$RC5_LINK" ]; then
                echo "服务：runit 无原生服务，已用 init 脚本 + rc.local 兜底"
            else
                echo "服务：未发现 runit 服务（${SERVICE_BASE}）"
            fi
            ;;
        *)
            # sysvinit：检查 rc5 的 S 链接是否指向我们的 init 脚本
            if [ -L "$RC5_LINK" ] || ls /etc/rc*.d/ 2>/dev/null | grep -qi displaylink; then
                echo "服务：sysvinit 已启用（rc*.d 有链接）"
            else
                echo "服务：sysvinit 未启用"
            fi
            ;;
    esac

    # 进程
    if pgrep -f 'DisplayLinkManager' >/dev/null; then
        echo "进程：$(pgrep -af 'DisplayLinkManager' | head -n 3 | tr '\n' '; ')"
    else
        echo "进程：未运行"
    fi
    # 内核模块
    lsmod | grep -q '^evdi' && echo "内核模块：evdi 已加载" || echo "内核模块：evdi 未加载"
    if need_cmd dkms; then
        local dkms_evdi
        dkms_evdi="$(dkms status 2>/dev/null | grep -i evdi | head -n 1 || true)"
        [ -n "$dkms_evdi" ] && echo "DKMS：${dkms_evdi}"
    fi

    # 版本
    if [ -x "$DISPLAYLINK_BIN" ]; then
        local dlm_ver
        dlm_ver="$("$DISPLAYLINK_BIN" -version 2>/dev/null | head -n 1 || true)"
        echo "驱动版本：${dlm_ver:-未知}（.run 方式）"
    elif [ -f "$DRIVER_VERSION_FILE" ]; then
        echo "驱动版本：$(cat "$DRIVER_VERSION_FILE")（.run 方式）"
    fi
    dpkg-query -W -f='驱动版本：${Version}（旧 APT 方式）\n' displaylink-driver 2>/dev/null || true
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
    local ans
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

main() {
    # 参数解析（先于 root 检查，便于 --help 普通用户使用）
    local MODE="install"

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --uninstall) MODE="uninstall" ;;
            --status)    MODE="status" ;;
            --help|-h)   MODE="help" ;;
            --run-file)
                [ "$#" -ge 2 ] || die "--run-file 需要一个 .zip / .run 文件路径"
                RUN_FILE_LOCAL="$2"
                shift
                ;;
            --run-file=*) RUN_FILE_LOCAL="${1#*=}" ;;
            --run-url)
                [ "$#" -ge 2 ] || die "--run-url 需要一个下载地址"
                DISPLAYLINK_DOWNLOAD_URL="$2"
                shift
                ;;
            --run-url=*) DISPLAYLINK_DOWNLOAD_URL="${1#*=}" ;;
            *) die "未知参数：$1（用 --help 查看用法）" ;;
        esac
        shift
    done

    if [ "$MODE" = "help" ]; then
        echo "用法："
        echo "  sudo $0                       下载官方 .run 安装包安装 + 配置开机自启动"
        echo "  sudo $0 --run-file FILE       使用本地 .zip / .run 安装包（离线安装）"
        echo "  sudo $0 --run-url URL         指定 .zip / .run 下载地址"
        echo "  sudo $0 --status              只查看当前状态"
        echo "  sudo $0 --uninstall           彻底卸载"
        exit 0
    fi

    # root 检查（安装 / 卸载 / 状态都涉及系统操作，统一要求 root）
    if [ "$(id -u)" -ne 0 ]; then
        die "请使用 root 运行：sudo $0"
    fi

    INIT="$(detect_init)"
    info "=== DisplayLink MX Linux 安装脚本 v${VERSION} ==="
    info "发行版：$(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"
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
    install_pkgs lsb-release wget curl ca-certificates unzip
    install_kernel_headers

    # 2) 安装驱动（下载官方 .run 安装包并运行官方 installer；已装则跳过）
    info "== 检查 / 安装 DisplayLink 驱动（官方 .run） =="
    ensure_driver_installed

    # 3) evdi 内核模块（官方 installer 已用 DKMS 编译；缺失时用 evdi-dkms 回退）
    info "== 检查 evdi 内核模块（DKMS） =="
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
    info "官方安装器日志：/var/log/displaylink/displaylink_installer.log"
    info "如需卸载：sudo $0 --uninstall"
}

# 仅当直接执行（非 source）时运行主流程
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
