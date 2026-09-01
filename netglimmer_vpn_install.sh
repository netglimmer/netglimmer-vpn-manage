#!/bin/bash

#################################################################
# Netglimmer VPN 一键安装部署脚本 (Go + Vue 重构版)
# 支持系统: Debian/Ubuntu
# 功能: 安装、卸载、用户管理、在线管理、流量统计、配置管理
# 架构: Go 后端 + SQLite + Vue 3 前端 + WebSocket 实时推送
#################################################################

set -e

# 保存脚本所在目录的绝对路径（必须在任何 cd 之前执行）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

OCSERV_CONF="/etc/ocserv/ocserv.conf"
OCSERV_PASSWD="/etc/ocserv/ocpasswd"
OCSERV_ROUTES="/etc/ocserv/routes.txt"
# Debian 12 apt 仓库的 ocserv 为 1.1.6，早于 camouflage（服务伪装）引入的 1.1.7，
# 故不再用 apt 安装，改为源码编译指定版本。camouflage 需 >= 1.1.7；1.5.0 经评估与本项目功能无冲突。
OCSERV_VERSION="1.5.0"
# 采用本地离线源码包安装（不进行在线下载）。默认查找脚本同目录下的 ocserv-${OCSERV_VERSION}.tar.xz，
# 也可用环境变量 OCSERV_SRC_FILE 指定其它路径。
OCSERV_SRC_FILE="${OCSERV_SRC_FILE:-}"

# === 完全离线安装模式 ===
# 模式决定优先级（从高到低）：
#   1. 命令行参数 --offline         → 强制离线（离线包缺失时中止）
#   2. 环境变量 OFFLINE_MODE=true/false → 显式强制
#   3. 安装时交互询问，由用户选择（默认项根据 offline-debs/ 是否就绪自动推荐）
# 离线模式下：不改动系统 apt 源、不执行 apt-get update，系统依赖全部由本地 offline-debs/*.deb 安装；
# 前端依赖优先使用随包 node_modules；Go 后端优先使用 vendor 目录离线编译。
OFFLINE_MODE="${OFFLINE_MODE:-}"   # 留空 = 安装时交互询问；true/false = 显式强制
OFFLINE_FLAG="false"               # 是否显式传入 --offline 参数
for _a in "$@"; do
    [[ "$_a" == "--offline" ]] && OFFLINE_FLAG="true"
done
# 过滤掉 --offline 参数，保持既有位置参数语义（install/uninstall/console/manage）
_ARGS=()
for _a in "$@"; do
    [[ "$_a" != "--offline" ]] && _ARGS+=("$_a")
done
set -- "${_ARGS[@]:-}"
OCSERV_SERVICE="/etc/systemd/system/ocserv.service"
CA_CERT="/etc/ocserv/ssl/ca-cert.pem"
SERVER_CERT="/etc/ocserv/ssl/server-cert.pem"
SERVER_KEY="/etc/ocserv/ssl/server-key.pem"

MANAGER_DIR="/opt/ocserv-manager"
MANAGER_SERVICE="/etc/systemd/system/ocserv-manager.service"
DB_PATH="/etc/ocserv/ocserv-manager.db"

# 预编译二进制交付模式：包内带 ocserv-manager 可执行文件且无 backend/ 源码目录时启用。
# 该模式下跳过 Go/Node 安装与前端/后端编译，直接安装二进制；
# HMAC 主密钥仍按原逻辑生成（发布版二进制运行时读取 /etc/.nglickey）。
# 源码目录（含 backend/）不受影响，自动走原有编译流程。
PREBUILT_BINARY="false"
if [[ -f "$SCRIPT_DIR/ocserv-manager" && ! -d "$SCRIPT_DIR/backend" ]]; then
    PREBUILT_BINARY="true"
fi

NGINX_SSL_DIR="/etc/ocserv/ssl/nginx"
NGINX_SSL_CERT="${NGINX_SSL_DIR}/nginx-selfsigned.crt"
NGINX_SSL_KEY="${NGINX_SSL_DIR}/nginx-selfsigned.key"
NGINX_SITE_CONF="/etc/nginx/sites-available/ocserv-panel"

print_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# === 进度条/明细模式 ===
VERBOSE_MODE=false
CONSOLE_PASSWORD="Netglimmer"
INSTALL_LOG="/tmp/netglimmer-install.log"

# === 安装保护与回退 ===
# 重装前对现有安装做全量快照；安装失败/被中断时自动回退到安装前状态，避免生产服务停摆。
BACKUP_ROOT="/var/lib/netglimmer-backup"
SNAPSHOT_DIR=""     # 本次安装的快照目录（重装时创建）
PRIOR_STATE=""      # reinstall = 已有历史安装；fresh = 全新安装
RUN_STEP_BG_PID=""  # run_step 后台执行的步骤进程（供中断时清理）
# 步骤子状态文件：长耗时步骤可通过 step_status "文本" 实时更新子进度，
# 进度模式的动画行会附加显示，避免用户误判安装已卡死
STEP_STATUS_FILE="/tmp/netglimmer-step-status.$$"
PKG_LOCK_WAIT_MAX=600   # 等待软件包管理器锁释放的最长秒数

# 进度条显示: show_progress step_num total_steps step_name
show_progress() {
    local step=$1 total=$2 name=$3
    local pct=$((step * 100 / total))
    local filled=$((pct / 2))
    local empty=$((50 - filled))
    local clear=""
    [[ -t 1 ]] && clear=$'\033[K'   # TTY 下清除动画帧残留字符；非 TTY 不输出转义符
    printf "\r${clear}  ["
    printf "%0.s=" $(seq 1 $filled 2>/dev/null) 2>/dev/null || true
    printf "%0.s-" $(seq 1 $empty 2>/dev/null) 2>/dev/null || true
    printf "] %3d%%  %s" "$pct" "$name"
}

# 步骤执行动画帧（盲文旋转符）
SPINNER_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

hide_cursor() { printf '\e[?25l'; }
show_cursor() { printf '\e[?25h'; }

# 更新当前步骤的子状态文本（由 animate_step 实时附加显示；空文本 = 清除）
step_status() { printf '%s\n' "$1" > "$STEP_STATUS_FILE" 2>/dev/null || true; }

# 步骤执行期间的动态渲染：旋转 spinner + 实时秒数 + 进度条平滑推进 + 百分比渐近递增，
# 避免长时间步骤（如安装依赖）期间画面完全静止，让用户明确感知安装仍在进行。
# animate_step step total "step_name" cmd_pid start_ts base_pct target_pct
animate_step() {
    local step=$1 total=$2 name=$3 pid=$4 start_ts=$5 base_pct=$6 target_pct=$7
    local base_cells=$((base_pct / 2))
    local seg_cells=$(( (target_pct - base_pct) / 2 ))
    [[ $seg_cells -lt 1 ]] && seg_cells=1
    local i=0 disp_pct=$base_pct
    hide_cursor
    while kill -0 "$pid" 2>/dev/null; do
        local now=$(( $(date +%s) ))
        local elapsed=$(( now - start_ts ))
        local frame="${SPINNER_FRAMES[i % ${#SPINNER_FRAMES[@]}]}"
        # 百分比渐近逼近本步目标值：永远增长但不会提前到达，完成时跳到精确目标值
        disp_pct=$(( base_pct + (target_pct - base_pct) * elapsed / (elapsed + 12) ))
        [[ $disp_pct -ge $target_pct ]] && disp_pct=$((target_pct - 1))
        # 进度条 = 已完成段(=) + 当前步推进段(彗星 > 在 · 上往复扫描) + 未开始段(-)
        local comet=$(( i / 2 % seg_cells ))
        local bar="" c
        for ((c = 0; c < base_cells; c++)); do bar+="="; done
        for ((c = 0; c < seg_cells; c++)); do
            [[ $c -eq $comet ]] && bar+=">" || bar+="·"
        done
        for ((c = 0; c < 50 - base_cells - seg_cells; c++)); do bar+="-"; done
        # 附加步骤内部上报的子状态（如离线包安装计数），让用户看到长步骤的真实进展
        local extra=""
        [[ -f "$STEP_STATUS_FILE" ]] && extra=" | $(head -1 "$STEP_STATUS_FILE" 2>/dev/null)"
        printf "\r\033[K  ${CYAN:-}[%s]${NC} %3d%%  ${YELLOW:-}%s${NC} %s%s... (${elapsed}s)" \
            "$bar" "$disp_pct" "$frame" "$name" "$extra"
        i=$((i + 1))
        sleep 0.1
    done
    show_cursor
}

# 带进度条执行步骤: run_step step_num total_steps "EN name" "ZH name" function_name [args...]
# 明细模式用进程替换（而非管道 tee）镜像输出到日志：管道会产生子 shell，
# 步骤函数内的 export PATH 等环境变更会丢失；进程替换下步骤在当前 shell 直接执行。
# 进度模式（非 TTY 除外）下步骤放到后台执行，前台跑 animate_step 动画循环实时渲染。
run_step() {
    local step=$1 total=$2 en_name=$3 zh_name=$4
    shift 4
    local step_name
    if [[ "$LANG_CHOICE" == "zh" ]]; then
        step_name="$zh_name"
    else
        step_name="$en_name"
    fi
    local start_ts=$(date +%s)
    local rc=0
    rm -f "$STEP_STATUS_FILE" 2>/dev/null || true
    if [[ "$VERBOSE_MODE" == "true" ]]; then
        # 明细模式：步骤横幅分隔 + 步骤输出实时 tee 到终端与日志
        echo ""
        echo "==================== [$step/$total] $(msg "$en_name" "$zh_name") ====================" | tee -a "$INSTALL_LOG"
        show_progress $((step - 1)) "$total" "$step_name..."
        echo ""
        echo "[$(date '+%F %T')] [$step/$total] $(msg "$en_name" "$zh_name") ..." | tee -a "$INSTALL_LOG"
        "$@" > >(tee -a "$INSTALL_LOG") 2>&1
        rc=$?
    elif [[ -t 1 ]]; then
        # TTY：后台执行步骤，前台动画实时渲染（spinner + 秒数 + 进度条推进）
        local base_pct=$(( (step - 1) * 100 / total ))
        local target_pct=$(( step * 100 / total ))
        "$@" >>"$INSTALL_LOG" 2>&1 &
        RUN_STEP_BG_PID=$!
        animate_step "$step" "$total" "$step_name" "$RUN_STEP_BG_PID" "$start_ts" "$base_pct" "$target_pct"
        wait "$RUN_STEP_BG_PID" 2>/dev/null || rc=$?
        RUN_STEP_BG_PID=""
    else
        # 非 TTY（输出被重定向/管道）：保持静态渲染，避免动画转义符污染日志
        show_progress $((step - 1)) "$total" "$step_name..."
        echo ""
        "$@" >>"$INSTALL_LOG" 2>&1
        rc=$?
    fi
    rm -f "$STEP_STATUS_FILE" 2>/dev/null || true
    local elapsed=$(( $(date +%s) - start_ts ))
    if [[ $rc -eq 0 ]]; then
        show_progress "$step" "$total" "$step_name ✓ (${elapsed}s)"
        echo ""
        echo "[$(date '+%F %T')] [$step/$total] $step_name ✓ (${elapsed}s)" >> "$INSTALL_LOG"
    else
        local clear=""
        [[ -t 1 ]] && clear=$'\033[K'
        printf "\r${clear}  ✗ %s $(msg "FAILED" "失败") (${elapsed}s)\n" "$step_name"
        echo "[$(date '+%F %T')] [$step/$total] $step_name ✗ (${elapsed}s)" >> "$INSTALL_LOG"
        return $rc
    fi
}

# console 模式密码验证
verify_console_password() {
    local pass
    read -s -p "$(msg "Enter console password" "请输入控制台密码"): " pass
    echo ""
    if [[ "$pass" != "$CONSOLE_PASSWORD" ]]; then
        berror "Incorrect password" "密码错误"
        exit 1
    fi
    VERBOSE_MODE=true
    bsuccess "Console mode activated (verbose logging)" "控制台模式已激活（明细日志）"
    binfo "Step details will stream live and also be recorded in: $INSTALL_LOG" "各步骤明细将实时输出，同时记录到: $INSTALL_LOG"
}

# 安装前快照：记录服务状态、配置、数据、防火墙规则，供失败时回退
snapshot_existing_install() {
    SNAPSHOT_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$SNAPSHOT_DIR/units"
    # 服务启停/自启状态（回退时按此恢复）
    {
        echo "ocserv_active=$(systemctl is-active --quiet ocserv 2>/dev/null && echo true || echo false)"
        echo "ocserv_enabled=$(systemctl is-enabled ocserv 2>/dev/null || echo disabled)"
        echo "manager_active=$(systemctl is-active --quiet ocserv-manager 2>/dev/null && echo true || echo false)"
        echo "manager_enabled=$(systemctl is-enabled ocserv-manager 2>/dev/null || echo disabled)"
    } > "$SNAPSHOT_DIR/state.env"
    if [[ -d /etc/ocserv ]]; then cp -a /etc/ocserv "$SNAPSHOT_DIR/etc-ocserv"; fi
    if [[ -d /etc/ocserv-panel ]]; then cp -a /etc/ocserv-panel "$SNAPSHOT_DIR/etc-ocserv-panel"; fi
    if [[ -d "$MANAGER_DIR" ]]; then cp -a "$MANAGER_DIR" "$SNAPSHOT_DIR/manager"; fi
    local u
    for u in ocserv.service ocserv-manager.service; do
        if [[ -f "/etc/systemd/system/$u" ]]; then cp -a "/etc/systemd/system/$u" "$SNAPSHOT_DIR/units/"; fi
    done
    if [[ -f /etc/sysctl.d/60-ocserv.conf ]]; then cp -a /etc/sysctl.d/60-ocserv.conf "$SNAPSHOT_DIR/sysctl-60-ocserv.conf"; fi
    if [[ -f "$NGINX_SITE_CONF" ]]; then cp -a "$NGINX_SITE_CONF" "$SNAPSHOT_DIR/nginx-ocserv-panel.conf"; fi
    iptables-save > "$SNAPSHOT_DIR/rules.v4" 2>/dev/null || true
    ip6tables-save > "$SNAPSHOT_DIR/rules.v6" 2>/dev/null || true
    ipset save > "$SNAPSHOT_DIR/ipsets.v4" 2>/dev/null || true
    bsuccess "Pre-install snapshot saved: $SNAPSHOT_DIR (auto-rollback on failure)" "安装前快照已保存: $SNAPSHOT_DIR（失败时自动回退）"
    # 仅保留最近 3 份快照
    ls -1dt "$BACKUP_ROOT"/*/ 2>/dev/null | tail -n +4 | xargs -r rm -rf
}

# 回退到安装前快照（尽力而为，单项失败不中断整体回退）
restore_from_snapshot() {
    if [[ -z "${SNAPSHOT_DIR:-}" || ! -d "$SNAPSHOT_DIR" ]]; then
        berror "No snapshot available, cannot roll back" "没有可用快照，无法回退"
        return 1
    fi
    trap - INT TERM
    binfo "Rolling back to pre-install snapshot..." "正在回退到安装前快照..."
    systemctl stop ocserv ocserv-manager 2>/dev/null || true

    # 配置与数据目录
    rm -rf /etc/ocserv /etc/ocserv-panel "$MANAGER_DIR"
    if [[ -d "$SNAPSHOT_DIR/etc-ocserv" ]]; then cp -a "$SNAPSHOT_DIR/etc-ocserv" /etc/ocserv; fi
    if [[ -d "$SNAPSHOT_DIR/etc-ocserv-panel" ]]; then cp -a "$SNAPSHOT_DIR/etc-ocserv-panel" /etc/ocserv-panel; fi
    if [[ -d "$SNAPSHOT_DIR/manager" ]]; then cp -a "$SNAPSHOT_DIR/manager" "$MANAGER_DIR"; fi

    # 服务单元（本次安装新建而原先不存在的 unit 需清理）
    if [[ -f "$SNAPSHOT_DIR/units/ocserv.service" ]]; then
        cp -a "$SNAPSHOT_DIR/units/ocserv.service" "$OCSERV_SERVICE"
    else
        rm -f "$OCSERV_SERVICE"
    fi
    if [[ -f "$SNAPSHOT_DIR/units/ocserv-manager.service" ]]; then
        cp -a "$SNAPSHOT_DIR/units/ocserv-manager.service" "$MANAGER_SERVICE"
    else
        rm -f "$MANAGER_SERVICE"
    fi

    # sysctl 与 nginx 站点配置
    rm -f /etc/sysctl.d/60-ocserv.conf
    if [[ -f "$SNAPSHOT_DIR/sysctl-60-ocserv.conf" ]]; then cp -a "$SNAPSHOT_DIR/sysctl-60-ocserv.conf" /etc/sysctl.d/60-ocserv.conf; fi
    rm -f "$NGINX_SITE_CONF" /etc/nginx/sites-enabled/ocserv-panel
    if [[ -f "$SNAPSHOT_DIR/nginx-ocserv-panel.conf" ]]; then
        cp -a "$SNAPSHOT_DIR/nginx-ocserv-panel.conf" "$NGINX_SITE_CONF"
        ln -sf "$NGINX_SITE_CONF" /etc/nginx/sites-enabled/ocserv-panel
    fi
    if systemctl is-active --quiet nginx 2>/dev/null; then nginx -s reload 2>/dev/null || true; fi

    # 防火墙：先清除本次安装创建的 ipset（IPv4/IPv6 双族），再忠实还原安装前快照
    ipset destroy ocserv_blacklist 2>/dev/null || true
    ipset destroy ocserv_blacklist6 2>/dev/null || true
    ipset destroy netglimmer_manual_ban 2>/dev/null || true
    ipset destroy netglimmer_manual_ban6 2>/dev/null || true
    ipset list -n 2>/dev/null | grep '^ocdom_' | while read -r s; do ipset destroy "$s" 2>/dev/null || true; done
    if [[ -f "$SNAPSHOT_DIR/rules.v4" ]]; then iptables-restore < "$SNAPSHOT_DIR/rules.v4" 2>/dev/null || true; fi
    if [[ -f "$SNAPSHOT_DIR/rules.v6" ]]; then ip6tables-restore < "$SNAPSHOT_DIR/rules.v6" 2>/dev/null || true; fi
    if [[ -f "$SNAPSHOT_DIR/ipsets.v4" ]]; then ipset restore < "$SNAPSHOT_DIR/ipsets.v4" 2>/dev/null || true; fi

    # 服务自启/运行状态
    local ocserv_active=false ocserv_enabled=disabled manager_active=false manager_enabled=disabled
    if [[ -f "$SNAPSHOT_DIR/state.env" ]]; then source "$SNAPSHOT_DIR/state.env"; fi
    systemctl daemon-reload 2>/dev/null || true
    if [[ "$ocserv_enabled" == "enabled" ]]; then
        systemctl enable ocserv 2>/dev/null || true
    else
        systemctl disable ocserv 2>/dev/null || true
    fi
    if [[ "$manager_enabled" == "enabled" ]]; then systemctl enable ocserv-manager 2>/dev/null || true; fi
    if [[ "$ocserv_active" == "true" ]]; then systemctl start ocserv 2>/dev/null || true; fi
    if [[ "$manager_active" == "true" ]]; then systemctl start ocserv-manager 2>/dev/null || true; fi

    if systemctl is-active --quiet ocserv 2>/dev/null || systemctl is-active --quiet ocserv-manager 2>/dev/null; then
        bsuccess "Rollback succeeded, original services restored" "回退成功，原有服务已恢复运行"
    else
        bwarning "Rollback completed, but services not running. Check manually (snapshot: $SNAPSHOT_DIR)" "回退已完成，但服务未自动运行，请手动检查（快照: $SNAPSHOT_DIR）"
    fi
    return 0
}

# 递归终止进程树（先杀子孙再杀自身）：中断时确保 dpkg 等子进程不残留占锁
_kill_proc_tree() {
    local pid=$1 c
    for c in $(pgrep -P "$pid" 2>/dev/null); do
        _kill_proc_tree "$c"
    done
    kill -TERM "$pid" 2>/dev/null || true
}

# 安装中断处理：先清理 run_step 后台步骤进程并恢复光标，再进入失败/回退流程
on_install_interrupt() {
    local sig="${1:-INT}"
    if [[ -n "$RUN_STEP_BG_PID" ]]; then
        _kill_proc_tree "$RUN_STEP_BG_PID"
        wait "$RUN_STEP_BG_PID" 2>/dev/null || true
        RUN_STEP_BG_PID=""
    fi
    printf '\e[?25h' 2>/dev/null || true   # 恢复光标显示
    release_build_swap   # 中断时清理临时 swapfile，避免 2GB 磁盘占用残留
    if [[ "$sig" == "TSTP" ]]; then
        bwarning "Ctrl+Z suspend detected: treated as abort to prevent a leftover dpkg holding the package lock" \
                 "检测到 Ctrl+Z 挂起：为防止 dpkg 残留占用软件包锁，已按中断处理"
    fi
    handle_install_failure
}

# 安装失败/中断统一处理：展示日志尾部 + （重装场景）自动回退到安装前状态
handle_install_failure() {
    rm -f "$STEP_STATUS_FILE" 2>/dev/null || true
    release_build_swap   # 失败退出前清理临时 swapfile
    echo ""
    berror "Installation failed!" "安装失败!"
    if [[ -f "$INSTALL_LOG" ]]; then
        berror "Last 20 lines of install log:" "安装日志最后 20 行:"
        echo "---"
        tail -20 "$INSTALL_LOG"
        echo "---"
        binfo "Full log: $INSTALL_LOG" "完整日志: $INSTALL_LOG"
    fi
    if [[ "${PRIOR_STATE:-}" == "reinstall" ]]; then
        bwarning "Reinstall detected, attempting automatic rollback to pre-install state..." "检测到重装场景，正在尝试自动回退到安装前状态..."
        restore_from_snapshot \
            || berror "Rollback failed. Snapshot preserved at $SNAPSHOT_DIR, please restore manually" "回退失败。快照保留在 $SNAPSHOT_DIR，请手动恢复"
    else
        binfo "Fresh install failed: rerun this script to continue, or use the uninstall option to clean up leftovers" "全新安装失败: 可重新运行脚本继续安装，或使用卸载功能清理残留"
    fi
    exit 1
}

# === 双语支持 ===
LANG_CHOICE=""

choose_language() {
    echo ""
    echo "  Select language / 选择语言:"
    echo "    [1] English"
    echo "    [2] 中文"
    echo ""
    read -p "  [1]: " lang_input
    case "$lang_input" in
        2) LANG_CHOICE="zh" ;;
        *) LANG_CHOICE="en" ;;
    esac
    echo ""
}

# 双语消息函数: msg "English text" "Chinese text"
msg() {
    if [[ "$LANG_CHOICE" == "zh" ]]; then
        echo "$2"
    else
        echo "$1"
    fi
}

# 双语输出函数: binfo/bsuccess/bwarning/berror "English" "Chinese"
binfo()    { print_info "$(msg "$1" "$2")"; }
bsuccess() { print_success "$(msg "$1" "$2")"; }
bwarning() { print_warning "$(msg "$1" "$2")"; }
berror()   { print_error "$(msg "$1" "$2")"; }

# 双语 read -p: bread "English prompt" "Chinese prompt" "default"
bread() {
    local prompt
    if [[ "$LANG_CHOICE" == "zh" ]]; then
        prompt="$2"
    else
        prompt="$1"
    fi
    if [[ -n "${3:-}" ]]; then
        read -p "${prompt} [${3}]: " BREAD_RESULT
    else
        read -p "${prompt}: " BREAD_RESULT
    fi
}

is_valid_ip() {
    local ip=$1
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && return 0
    return 1
}

is_valid_address() {
    local addr=$1
    [[ "$addr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && return 0
    [[ "$addr" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] && return 0
    return 1
}

is_valid_network() {
    local net=$1
    [[ "$net" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] && return 0
    return 1
}

is_port_in_use() {
    local port=$1
    command -v ss >/dev/null 2>&1 && ss -tuln | grep -q ":$port " && return 0
    command -v netstat >/dev/null 2>&1 && netstat -tuln | grep -q ":$port " && return 0
    command -v lsof >/dev/null 2>&1 && lsof -i :$port >/dev/null 2>&1 && return 0
    return 1
}

is_number() {
    [[ "$1" =~ ^[0-9]+$ ]] && return 0
    return 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        berror "This script must be run as root" "此脚本必须以 root 用户运行"
        exit 1
    fi
}

check_system() {
    if [[ -f /etc/debian_version ]]; then
        OS="debian"
        binfo "Detected Debian/Ubuntu system" "检测到 Debian/Ubuntu 系统"
    else
        berror "Unsupported OS, only Debian/Ubuntu supported" "不支持的操作系统，仅支持 Debian/Ubuntu"
        exit 1
    fi
}

get_server_ip() {
    ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1'
}

netmask_to_cidr() {
    local netmask=$1
    local bits=0
    local IFS=.
    for octet in $netmask; do
        case $octet in
            255) bits=$((bits + 8));;
            254) bits=$((bits + 7));;
            252) bits=$((bits + 6));;
            248) bits=$((bits + 5));;
            240) bits=$((bits + 4));;
            224) bits=$((bits + 3));;
            192) bits=$((bits + 2));;
            128) bits=$((bits + 1));;
            0) ;;
            *) return 1;;
        esac
    done
    echo $bits
}

configure_mirror() {
    binfo "Configuring mirror sources for faster installation..." "配置国内镜像源以加速安装..."
    [[ ! -f /etc/apt/sources.list.bak ]] && cp /etc/apt/sources.list /etc/apt/sources.list.bak 2>/dev/null || true
    local release_name=$(lsb_release -cs 2>/dev/null || grep -oP '(?<=VERSION_CODENAME=).*' /etc/os-release | tr -d '"')
    local is_ubuntu=$(grep -qi "ubuntu" /etc/os-release && echo "true" || echo "false")

    if [[ "$is_ubuntu" == "true" ]]; then
        cat > /etc/apt/sources.list <<EOF
deb http://mirrors.aliyun.com/ubuntu/ ${release_name} main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ ${release_name}-security main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ ${release_name}-updates main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ ${release_name}-backports main restricted universe multiverse
EOF
    else
        cat > /etc/apt/sources.list <<EOF
deb http://mirrors.aliyun.com/debian/ ${release_name} main contrib non-free non-free-firmware
deb http://mirrors.aliyun.com/debian/ ${release_name}-updates main contrib non-free non-free-firmware
deb http://mirrors.aliyun.com/debian/ ${release_name}-backports main contrib non-free non-free-firmware
deb http://mirrors.aliyun.com/debian-security/ ${release_name}-security main contrib non-free non-free-firmware
EOF
    fi
    bsuccess "Mirror sources configured" "镜像源配置完成"
}

apt_update_with_fallback() {
    binfo "Updating package lists..." "更新软件包列表..."

    if apt-get update -y 2>/dev/null; then
        return 0
    fi

    bwarning "Aliyun mirror failed, trying Tsinghua mirror..." "阿里云镜像更新失败，尝试清华镜像..."
    local release_name=$(lsb_release -cs 2>/dev/null || grep -oP '(?<=VERSION_CODENAME=).*' /etc/os-release | tr -d '"')
    if grep -qi "ubuntu" /etc/os-release; then
        cat > /etc/apt/sources.list <<EOF
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${release_name} main restricted universe multiverse
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${release_name}-security main restricted universe multiverse
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${release_name}-updates main restricted universe multiverse
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${release_name}-backports main restricted universe multiverse
EOF
    else
        cat > /etc/apt/sources.list <<EOF
deb http://mirrors.tuna.tsinghua.edu.cn/debian/ ${release_name} main contrib non-free non-free-firmware
deb http://mirrors.tuna.tsinghua.edu.cn/debian/ ${release_name}-updates main contrib non-free non-free-firmware
deb http://mirrors.tuna.tsinghua.edu.cn/debian/ ${release_name}-backports main contrib non-free non-free-firmware
deb http://mirrors.tuna.tsinghua.edu.cn/debian-security ${release_name}-security main contrib non-free non-free-firmware
EOF
    fi

    if apt-get update -y 2>/dev/null; then
        return 0
    fi

    bwarning "Tsinghua mirror also failed, restoring default sources..." "清华镜像也失败，恢复默认源并尝试..."
    if [[ -f /etc/apt/sources.list.bak ]]; then
        cp /etc/apt/sources.list.bak /etc/apt/sources.list
        apt-get update -y || { berror "Package source update failed, please check network" "软件源更新失败，请检查网络连接"; return 1; }
    else
        berror "Package source update failed, please check network" "软件源更新失败，请检查网络连接"
        return 1
    fi
}

# ===== 完全离线安装支持 =====
# 本地离线 deb 包目录：随包分发 offline-debs/*.deb（由联网机执行 pack_offline_debs.sh 生成）
offline_deb_dir() { echo "${SCRIPT_DIR}/offline-debs"; }

# 离线 deb 包是否就绪：同目录 offline-debs/ 存在且含 .deb
offline_deb_available() {
    local d
    d="$(offline_deb_dir)"
    [[ -d "$d" ]] && ls "$d"/*.deb >/dev/null 2>&1
}

# 安装模式选择：--offline / OFFLINE_MODE 环境变量可显式强制，否则安装时交互询问用户
choose_install_mode() {
    local d deb_count choice
    d="$(offline_deb_dir)"

    # 1) 显式强制离线：--offline 参数或 OFFLINE_MODE=true
    if [[ "$OFFLINE_FLAG" == "true" || "$OFFLINE_MODE" == "true" ]]; then
        if offline_deb_available; then
            OFFLINE_MODE="true"
            binfo "Fully-offline install mode enabled (explicit request)" "已启用完全离线安装模式（显式指定）"
            return 0
        fi
        berror "Offline mode requested but offline deb directory not found or empty: $d" "要求离线安装，但未找到离线 deb 包目录或目录为空: $d"
        binfo "Run pack_offline_debs.sh on an online machine of the same distribution to generate it" "请在同发行版联网机器上执行 pack_offline_debs.sh 生成离线包"
        exit 1
    fi

    # 2) 显式强制在线：OFFLINE_MODE=false
    if [[ "$OFFLINE_MODE" == "false" ]]; then
        binfo "Online install mode enabled (OFFLINE_MODE=false)" "已启用在线安装模式 (OFFLINE_MODE=false)"
        return 0
    fi

    # 3) 交互询问，由用户决定
    if offline_deb_available; then
        deb_count=$(ls "$d"/*.deb 2>/dev/null | wc -l)
        binfo "Offline deb bundle detected: $d ($deb_count packages)" "检测到离线 deb 包: $d（共 $deb_count 个包）"
        while true; do
            bread "Select install mode: [1] Fully offline install (recommended, no network required) [2] Online install [1]" \
                  "请选择安装方式: [1] 完全离线安装（推荐，全程无需联网） [2] 在线安装 [1]" ""
            choice="${BREAD_RESULT:-1}"
            case "$choice" in
                1) OFFLINE_MODE="true";  bsuccess "Fully offline install selected" "已选择完全离线安装"; return 0 ;;
                2) OFFLINE_MODE="false"; bsuccess "Online install selected" "已选择在线安装"; return 0 ;;
                *) berror "Invalid selection, please enter 1 or 2" "无效选择，请输入 1 或 2" ;;
            esac
        done
    else
        bwarning "No offline deb bundle detected: $d" "未检测到离线 deb 包目录: $d"
        while true; do
            bread "Select install mode: [1] Online install (recommended) [2] Fully offline install (requires offline-debs/) [1]" \
                  "请选择安装方式: [1] 在线安装（推荐） [2] 完全离线安装（需 offline-debs/） [1]" ""
            choice="${BREAD_RESULT:-1}"
            case "$choice" in
                1) OFFLINE_MODE="false"; bsuccess "Online install selected" "已选择在线安装"; return 0 ;;
                2)
                    if offline_deb_available; then
                        OFFLINE_MODE="true"; bsuccess "Fully offline install selected" "已选择完全离线安装"; return 0
                    fi
                    berror "Offline deb package missing, unable to install offline. Generate it with pack_offline_debs.sh first." "离线 deb 包缺失，无法离线安装。请先在联网机器执行 pack_offline_debs.sh 生成。"
                    ;;
                *) berror "Invalid selection, please enter 1 or 2" "无效选择，请输入 1 或 2" ;;
            esac
        done
    fi
}

# 软件包管理器锁等待：上一次安装被 Ctrl+Z 挂起/异常中断后，dpkg 可能仍在后台运行或残留持锁，
# 直接安装会报 "Could not get lock /var/lib/dpkg/lock-frontend"。这里先探测并等待持锁进程结束。
wait_pkg_lock() {
    local max_wait=${PKG_LOCK_WAIT_MAX:-600} waited=0 holder_pid="" l
    local locks=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock)
    while true; do
        holder_pid=""
        for l in "${locks[@]}"; do
            [[ -e "$l" ]] || continue
            if command -v fuser >/dev/null 2>&1; then
                if fuser "$l" >/dev/null 2>&1; then
                    holder_pid=$(fuser "$l" 2>/dev/null | tr -s ' ' | sed 's/^ *//')
                    break
                fi
            elif command -v lsof >/dev/null 2>&1; then
                holder_pid=$(lsof -t "$l" 2>/dev/null | tr '\n' ' ')
                [[ -n "$holder_pid" ]] && break
            fi
        done
        # 无 fuser/lsof 时退化为进程名探测（粗略但可用）
        if [[ -z "$holder_pid" ]] && ! command -v fuser >/dev/null 2>&1 && ! command -v lsof >/dev/null 2>&1; then
            holder_pid=$(pgrep -x 'dpkg|apt-get' 2>/dev/null | tr '\n' ' ')
        fi
        [[ -z "$holder_pid" ]] && return 0
        if [[ $waited -eq 0 ]]; then
            bwarning "Package manager lock is held by another process (PID: $holder_pid), waiting for it to finish..." \
                     "软件包管理器锁被其他进程占用（PID: $holder_pid），等待其结束..."
            binfo "Common cause: a previous install was suspended (Ctrl+Z) or interrupted while dpkg was still running, or another apt/dpkg task is in progress" \
                  "常见原因：上次安装被 Ctrl+Z 挂起或中断后 dpkg 仍在运行，或另有 apt/dpkg 任务进行中"
        fi
        if [[ $waited -ge $max_wait ]]; then
            berror "Package lock not released after ${max_wait}s, aborting. End the leftover process manually, e.g.: kill $holder_pid" \
                   "等待软件包锁 ${max_wait}s 仍未释放，终止。请手动结束残留进程，例如: kill $holder_pid"
            return 1
        fi
        sleep 5
        waited=$((waited + 5))
    done
}

# 自愈中断事务：异常中断后 dpkg 可能遗留半配置包（updates/ 日志目录非空），先 configure -a 修复
repair_dpkg_interrupted() {
    if [[ -n "$(ls -A /var/lib/dpkg/updates 2>/dev/null)" ]]; then
        binfo "Detected incomplete dpkg transaction leftovers, repairing (dpkg --configure -a)..." \
              "检测到未完成的 dpkg 事务残留，自动修复中（dpkg --configure -a）..."
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a \
            || bwarning "dpkg --configure -a did not fully succeed, continuing anyway" "dpkg --configure -a 未完全成功，继续尝试安装"
    fi
}

# 扫描离线包目录，过滤掉已安装且版本不低于包内版本的 deb，输出待安装文件清单（每行一个路径）。
# 避免续装/重装场景下对全量包重复执行双轮 dpkg -i，大幅缩短安装时间。
offline_pending_debs() {
    local d f pkg ver inst
    d="$(offline_deb_dir)"
    for f in "$d"/*.deb; do
        pkg=$(dpkg-deb -f "$f" Package 2>/dev/null) || continue
        [[ -z "$pkg" ]] && continue
        ver=$(dpkg-deb -f "$f" Version 2>/dev/null)
        # 必须校验安装状态为 install ok installed：dpkg-query -W 对半装（half-installed）/
        # 已删残留配置（config-files）的包同样返回版本号，仅凭版本比较会误判已装而跳过，
        # 导致关键二进制（如 iptables）实际缺失但安装流程不报错
        inst=$(dpkg-query -W -f='${Status}|${Version}' "$pkg" 2>/dev/null || true)
        if [[ "$inst" == "install ok installed|"* ]]; then
            local cur_ver=${inst#install ok installed|}
            if dpkg --compare-versions "$cur_ver" ge "${ver:-0}" 2>/dev/null; then
                continue   # 确已安装且版本足够，跳过
            fi
        fi
        printf '%s\n' "$f"
    done
}

# 执行一轮 dpkg -i 并展示真实进度：解析输出中的 "Setting up" 行计数，写入步骤子状态供动画行显示；
# dpkg 输出不再丢弃——进度模式下进入安装日志（供故障排查），明细模式下实时回显到终端。
# 返回码经标记行从进程替换内部传回（规避管道子 shell 问题）。
_offline_dpkg_pass() {
    local pass=$1; shift
    local total=$# done_cnt=0 line rc=0
    step_status "$(msg "Installing offline packages (pass $pass) 0/$total" "正在安装离线依赖包（第 $pass 轮）0/$total")"
    while IFS= read -r line; do
        if [[ "$line" == __DPKG_RC__=* ]]; then
            rc=${line#__DPKG_RC__=}
            continue
        fi
        if [[ "$line" == "Setting up "* ]]; then
            done_cnt=$((done_cnt + 1))
            step_status "$(msg "Installing offline packages (pass $pass) $done_cnt/$total" "正在安装离线依赖包（第 $pass 轮）$done_cnt/$total")"
        fi
        echo "$line"
    done < <(DEBIAN_FRONTEND=noninteractive dpkg -i "$@" 2>&1; echo "__DPKG_RC__=$?")
    step_status ""
    return "$rc"
}

# 离线模式下从本地 deb 目录安装软件包：先过滤已装包，仅安装缺失/版本不足的包；
# dpkg 一次性传入全部待装包以自动解决包间依赖顺序，首轮有失败时二次执行自愈；
# 安装后逐个校验请求的包是否就绪
offline_pkg_install() {
    local d
    d="$(offline_deb_dir)"
    if [[ ! -d "$d" ]] || ! ls "$d"/*.deb >/dev/null 2>&1; then
        berror "Offline deb directory not found or empty: $d" "离线 deb 包目录不存在或为空: $d"
        binfo "Run pack_offline_debs.sh on an online machine of the same distribution to generate it" "请在同发行版联网机器上执行 pack_offline_debs.sh 生成离线包"
        return 1
    fi

    # 发行版匹配校验：deb 与发行版大版本强绑定，跨版本安装会导致依赖求解失败或
    # 编译链接错误。PACK_INFO 由 pack_offline_debs.sh 生成；旧包无标记时仅警告不阻断。
    if [[ -f "$d/PACK_INFO" ]]; then
        local pk_distro pk_ver pk_arch cur_distro cur_ver cur_arch
        pk_distro=$(grep -oP '(?<=^DISTRO_ID=).*' "$d/PACK_INFO" 2>/dev/null)
        pk_ver=$(grep -oP '(?<=^VERSION_ID=).*' "$d/PACK_INFO" 2>/dev/null)
        pk_arch=$(grep -oP '(?<=^ARCH=).*' "$d/PACK_INFO" 2>/dev/null)
        cur_distro=$(. /etc/os-release && echo "$ID")
        cur_ver=$(. /etc/os-release && echo "$VERSION_ID")
        cur_arch=$(dpkg --print-architecture 2>/dev/null)
        if [[ -n "$pk_distro" && "$pk_distro" != "$cur_distro" ]] || \
           [[ -n "$pk_ver" && "$pk_ver" != "$cur_ver" ]] || \
           [[ -n "$pk_arch" && -n "$cur_arch" && "$pk_arch" != "$cur_arch" ]]; then
            berror "Offline bundle mismatch: bundle=${pk_distro:-?} ${pk_ver:-?}/${pk_arch:-?}, this host=${cur_distro} ${cur_ver}/${cur_arch}. Regenerate offline-debs with pack_offline_debs.sh on a ${cur_distro} ${cur_ver} online machine." \
                   "离线包与本机不匹配：离线包=${pk_distro:-未知} ${pk_ver:-未知}/${pk_arch:-未知}，本机=${cur_distro} ${cur_ver}/${cur_arch}。请在 ${cur_distro} ${cur_ver} 联网机器上重新执行 pack_offline_debs.sh 生成离线包。"
            return 1
        fi
    else
        bwarning "No PACK_INFO marker in offline-debs (old bundle), cannot verify distro match" "离线包缺少 PACK_INFO 标记（旧包），无法校验发行版匹配，请自行确认离线包与本机发行版一致"
    fi

    local total_bundle f
    total_bundle=$(ls "$d"/*.deb 2>/dev/null | wc -l)
    local -a pending=()
    while IFS= read -r f; do pending+=("$f"); done < <(offline_pending_debs)

    if [[ ${#pending[@]} -eq 0 ]]; then
        step_status "$(msg "Offline packages all present, verifying" "离线包均已安装，正在校验")"
        bsuccess "All offline packages already installed (bundle: $total_bundle), skipping reinstall" \
                 "离线包均已安装到位（共 $total_bundle 个），跳过重复安装"
    else
        binfo "Installing offline packages: ${#pending[@]} pending (bundle total: $total_bundle)" \
              "正在安装离线依赖包: 待装 ${#pending[@]} 个（离线包共 $total_bundle 个）"
        if ! _offline_dpkg_pass 1 "${pending[@]}"; then
            # 二次执行：首轮可能因包间依赖顺序部分失败，重复安装可自愈
            binfo "First pass left dependency gaps, running self-heal pass..." "首轮存在依赖顺序失败，执行第二轮自愈安装..."
            _offline_dpkg_pass 2 "${pending[@]}" || true
        fi
        step_status ""
    fi

    local p missing=0
    for p in "$@"; do
        # 状态位必须为 install ok installed：半装/配置残留包 dpkg -s 也可能返回成功
        if [[ "$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null)" != "install ok installed" ]]; then
            berror "Offline bundle missing package: $p" "离线包中缺少软件包: $p"
            missing=1
        fi
    done
    # 关键命令实文件校验：防止包状态异常（半装/文件丢失）时 dpkg 状态位失真，
    # 确保运行时真正依赖的可执行文件在位（面板 NAT/访问控制依赖 iptables 全家桶）
    local cmd
    for cmd in iptables iptables-save ipset jq sqlite3 certtool; do
        if ! command -v "$cmd" >/dev/null 2>&1 && [[ ! -x "/usr/sbin/$cmd" ]]; then
            berror "Critical command missing after offline install: $cmd" "离线安装后关键命令缺失: $cmd"
            missing=1
        fi
    done
    [[ "$missing" -eq 0 ]] || return 1
    return 0
}

# 统一软件包安装入口：离线模式用本地 deb，在线模式走 apt-get；安装前先等待包管理器锁释放
pkg_install() {
    wait_pkg_lock || return 1
    if [[ "$OFFLINE_MODE" == "true" ]]; then
        offline_pkg_install "$@"
        return $?
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

# 创建/更新 ocserv systemd unit（源码安装不自带 unit）。
# reload 走 SIGHUP，与后端 WriteConfig 的 `systemctl reload ocserv` 语义一致；
# pid-file / socket-file 路径由 ocserv.conf 指定，unit 内 PIDFile 与之保持一致。
ensure_ocserv_service() {
    local ocserv_bin
    ocserv_bin=$(command -v ocserv || echo /usr/sbin/ocserv)
    cat > "$OCSERV_SERVICE" <<EOF
[Unit]
Description=OpenConnect SSL VPN server (Netglimmer, built from source)
After=network-online.target
Wants=network-online.target
Documentation=man:ocserv(8)

[Service]
Type=simple
PIDFile=/run/ocserv.pid
ExecStart=${ocserv_bin} --foreground --pid-file /run/ocserv.pid --config ${OCSERV_CONF}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# 从源码编译安装 ocserv（Debian 12 apt 仅 1.1.6，不支持 camouflage 伪装，须 >= 1.1.7）。
# 幂等：已安装且版本 >= 目标版本时跳过编译，仅确保 systemd unit 就绪。
install_ocserv_from_source() {
    if command -v ocserv >/dev/null 2>&1; then
        local cur_ver
        cur_ver=$(ocserv --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        if [[ -n "$cur_ver" ]] && dpkg --compare-versions "$cur_ver" ge "$OCSERV_VERSION"; then
            binfo "ocserv ${cur_ver} already installed (>= ${OCSERV_VERSION}), skip build" "已安装 ocserv ${cur_ver}（>= ${OCSERV_VERSION}），跳过编译"
            ensure_ocserv_service
            return 0
        fi
        bwarning "Existing ocserv ${cur_ver:-unknown} < ${OCSERV_VERSION}, rebuilding" "检测到 ocserv ${cur_ver:-未知} 低于 ${OCSERV_VERSION}，将重新编译"
    fi

    local work_dir tarball
    work_dir=$(mktemp -d /tmp/ocserv-build.XXXXXX) || { berror "mktemp failed" "创建临时目录失败"; return 1; }
    tarball="${work_dir}/ocserv-${OCSERV_VERSION}.tar.xz"

    binfo "Locating local ocserv ${OCSERV_VERSION} source package..." "查找本地 ocserv ${OCSERV_VERSION} 源码包..."

    # 仅使用本地离线源码包安装（不进行在线下载）。
    # 查找顺序：OCSERV_SRC_FILE 指定 > 脚本同目录 > 当前目录。
    local local_src="" cand
    for cand in "$OCSERV_SRC_FILE" "${SCRIPT_DIR}/ocserv-${OCSERV_VERSION}.tar.xz" "./ocserv-${OCSERV_VERSION}.tar.xz"; do
        if [[ -n "$cand" && -f "$cand" ]]; then local_src="$cand"; break; fi
    done

    if [[ -z "$local_src" ]]; then
        berror "Local ocserv source package not found" "未找到本地 ocserv 源码包"
        binfo "Please place ocserv-${OCSERV_VERSION}.tar.xz next to this script (or set OCSERV_SRC_FILE), then rerun." \
              "请将 ocserv-${OCSERV_VERSION}.tar.xz 放到脚本同目录（或用环境变量 OCSERV_SRC_FILE 指定路径）后重新运行。"
        binfo "Official URL: https://www.infradead.org/ocserv/download/ocserv-${OCSERV_VERSION}.tar.xz" \
              "官方下载地址：https://www.infradead.org/ocserv/download/ocserv-${OCSERV_VERSION}.tar.xz"
        rm -rf "$work_dir"; return 1
    fi

    binfo "Using local ocserv source: $local_src" "使用本地 ocserv 源码包: $local_src"
    if ! cp -f "$local_src" "$tarball" || ! tar -tJf "$tarball" >/dev/null 2>&1; then
        berror "Local ocserv source invalid or corrupted: $local_src" "本地 ocserv 源码包无效或损坏: $local_src"
        rm -rf "$work_dir"; return 1
    fi

    binfo "Extracting and building ocserv ${OCSERV_VERSION}..." "解压并编译 ocserv ${OCSERV_VERSION}..."
    if ! tar -xf "$tarball" -C "$work_dir"; then
        berror "Extract ocserv source failed" "解压 ocserv 源码失败"
        rm -rf "$work_dir"; return 1
    fi

    local src_dir="${work_dir}/ocserv-${OCSERV_VERSION}"
    if [[ ! -d "$src_dir" ]]; then
        berror "ocserv source dir not found: $src_dir" "未找到 ocserv 源码目录: $src_dir"
        rm -rf "$work_dir"; return 1
    fi

    # 源码补丁：ocserv 1.5.0 的 gperf 产物定义了非 static 的 in_word_set 函数；
    # 当链接解析到静态库 libseccomp.a（其 gperf 产物含同名函数）时，
    # 报 "multiple definition of in_word_set" 导致 ocserv-worker 链接失败。
    # 修复：用 gperf 的 lookup-function-name 指令把函数改名为 ocserv_in_word_set。
    # 注意：meson 检测到 gperf 时会从 http-heads.gperf 重新生成 http-heads.c，
    # 因此必须改 .gperf 源文件（同时兼改预生成 .c/.h，覆盖无 gperf 的回退路径）。
    if [[ -f "$src_dir/src/http-heads.gperf" ]] && ! grep -q "lookup-function-name" "$src_dir/src/http-heads.gperf"; then
        sed -i 's/^%readonly-tables$/%readonly-tables\n%define lookup-function-name ocserv_in_word_set/' \
            "$src_dir/src/http-heads.gperf"
        sed -i 's/\bin_word_set\b/ocserv_in_word_set/g' \
            "$src_dir/src/http-heads.c" "$src_dir/src/http-heads.h" "$src_dir/src/worker-http.c" 2>/dev/null
        binfo "Patched ocserv gperf symbol (in_word_set rename, libseccomp.a link fix)" \
              "已补丁 ocserv gperf 符号（in_word_set 改名，修复与 libseccomp.a 的链接冲突）"
    fi

    # ocserv 1.5.0 使用 Meson/Ninja 构建（不再有 ./configure）。
    # --prefix=/usr 让二进制落在 /usr/sbin/ocserv、/usr/bin/{occtl,ocpasswd}，与 apt 版路径一致；
    # llhttp/talloc/protobuf-c 若系统未装则用源码内置副本，故无需额外系统包。
    if ! ( cd "$src_dir" && meson setup build --prefix=/usr --sysconfdir=/etc --buildtype=release ); then
        berror "ocserv meson setup failed" "ocserv meson 配置失败"
        rm -rf "$work_dir"; return 1
    fi
    if ! ( cd "$src_dir" && ninja -C build ); then
        berror "ocserv build (ninja) failed" "ocserv 编译失败"
        rm -rf "$work_dir"; return 1
    fi
    if ! ( cd "$src_dir" && ninja -C build install ); then
        berror "ocserv install failed" "ocserv 安装失败"
        rm -rf "$work_dir"; return 1
    fi

    rm -rf "$work_dir"

    if ! command -v ocserv >/dev/null 2>&1; then
        berror "ocserv binary not found after install" "安装后未找到 ocserv 可执行文件"
        return 1
    fi

    ensure_ocserv_service
    bsuccess "ocserv $(ocserv --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) installed from source" "ocserv 源码编译安装完成"
    return 0
}

install_dependencies() {
    # 任何安装动作前：等待包管理器锁释放并自愈中断事务（上次 Ctrl+Z/异常中断后残留持锁的直接对症）
    wait_pkg_lock || exit 1
    repair_dpkg_interrupted

    # 离线模式不触碰系统 apt 源、不做 apt update，依赖全部来自本地离线包
    if [[ "$OFFLINE_MODE" != "true" ]]; then
        configure_mirror

        if ! apt_update_with_fallback; then
            berror "Failed to update package lists, installation aborted" "无法更新软件包列表，安装终止"
            exit 1
        fi
    fi

    binfo "Installing VPN service and system dependencies..." "安装 VPN 服务及系统依赖..."
    # 注意：不再从 apt 安装 ocserv（Debian 12 仅 1.1.6，不支持 camouflage 伪装），改为源码编译。
    # 这里安装 ocserv 编译所需的构建依赖，以及项目运行所需的系统工具。
    pkg_install \
        gnutls-bin iptables net-tools iproute2 openssl ca-certificates \
        jq ipset iptables-persistent lsb-release curl git sqlite3 \
        build-essential pkg-config gperf xz-utils meson ninja-build \
        libgnutls28-dev nettle-dev libtasn1-6-dev libtasn1-bin \
        libev-dev libprotobuf-c-dev protobuf-c-compiler \
        libseccomp-dev libreadline-dev liblz4-dev libnl-route-3-dev libtalloc-dev libpam0g-dev \
        || { berror "Dependency installation failed, installation aborted" "依赖包安装失败，安装终止"; exit 1; }
    bsuccess "System dependencies installed" "系统依赖安装完成"

    install_ocserv_from_source || { berror "ocserv build/install failed, installation aborted" "ocserv 编译安装失败，安装终止"; exit 1; }

    install_dnsmasq
}

# 安装 dnsmasq（域名资源动态放行功能依赖，由管理面板按需启用）
# 安装失败不阻断主流程：面板会检测 dnsmasq 可用性，不可用时功能开关置灰
install_dnsmasq() {
    binfo "Installing dnsmasq (domain resource dynamic allow)..." "安装 dnsmasq（域名资源动态放行）..."

    # 先写基础配置再装包：默认配置会绑全接口 53 端口，与 systemd-resolved(127.0.0.53) 冲突
    # 导致 postinst 启动失败；预置 interface=vpns* + bind-dynamic 后仅监听 ocserv 隧道设备
    mkdir -p /etc/dnsmasq.d
    cat > /etc/dnsmasq.d/ocserv-base.conf <<'EOF'
# Netglimmer VPN 域名资源动态放行基础配置（安装脚本生成，请勿手工修改）
# 上游 DNS 转发由管理面板生成: /etc/dnsmasq.d/ocserv-domains.conf
# ipset 条目由后端主动解析维护（Debian dnsmasq 未编译 ipset 支持，不使用 ipset= 指令）
port=53
bind-dynamic
interface=vpns*
except-interface=lo
no-dhcp-interface=vpns*
no-resolv
no-hosts
cache-size=1000
EOF

    if ! command -v dnsmasq >/dev/null 2>&1; then
        pkg_install dnsmasq \
            || { bwarning "dnsmasq installation failed, domain dynamic allow will be unavailable" "dnsmasq 安装失败，域名动态放行功能将不可用"; return 0; }
    fi

    # 由面板按需启停，安装后默认不自启
    systemctl stop dnsmasq 2>/dev/null || true
    systemctl disable dnsmasq 2>/dev/null || true

    if dnsmasq --test >/dev/null 2>&1; then
        bsuccess "dnsmasq installed (managed by panel, disabled by default)" "dnsmasq 安装完成（由面板按需启用，默认不自启）"
    else
        bwarning "dnsmasq config test failed" "dnsmasq 配置自检失败，请检查 /etc/dnsmasq.d/ocserv-base.conf"
    fi
}

install_go() {
    if [[ "$PREBUILT_BINARY" == "true" ]]; then
        binfo "Binary delivery mode: skip Go install" "二进制交付模式：跳过 Go 安装"
        return 0
    fi
    local GO_VERSION="1.23.3"

    # 确保 /usr/local/go/bin 在 PATH 中（兼容上次安装后未 source 的情况）
    if [[ -x /usr/local/go/bin/go ]]; then
        export PATH="$PATH:/usr/local/go/bin"
    fi

    # 检测本地是否已有可用的 Go
    if command -v go >/dev/null 2>&1; then
        local installed_ver
        installed_ver=$(go version 2>/dev/null | grep -oP 'go\K[0-9]+\.[0-9]+' | head -1)
        if [[ -n "$installed_ver" ]]; then
            local major minor
            major=$(echo "$installed_ver" | cut -d. -f1)
            minor=$(echo "$installed_ver" | cut -d. -f2)
            if [[ "$major" -gt 1 ]] || { [[ "$major" -eq 1 ]] && [[ "$minor" -ge 21 ]]; }; then
                binfo "Go $installed_ver already installed ($(which go)), skipping" "Go $installed_ver 已安装 ($(which go))，跳过"
                return 0
            else
                bwarning "Go $installed_ver too old (need >= 1.21), will update" "Go $installed_ver 版本过低（需要 >= 1.21），将更新"
            fi
        fi
    fi

    binfo "Installing Go ${GO_VERSION}..." "安装 Go ${GO_VERSION}..."
    local go_arch="amd64"
    [[ $(uname -m) == "aarch64" ]] && go_arch="arm64"

    local go_url="https://go.dev/dl/go${GO_VERSION}.linux-${go_arch}.tar.gz"
    local fallback_url="https://dl.google.com/go/go${GO_VERSION}.linux-${go_arch}.tar.gz"
    local go_tarball="/tmp/go.tar.gz"

    # 优先使用本地离线 Go 包（脚本同目录下 go${GO_VERSION}.linux-${go_arch}.tar.gz，或 GO_SRC_FILE 指定），
    # 避免 go.dev / dl.google.com 在部分网络环境下被重置（Connection reset）。
    local go_local="" gc
    for gc in "${GO_SRC_FILE:-}" "${SCRIPT_DIR}/go${GO_VERSION}.linux-${go_arch}.tar.gz"; do
        if [[ -n "$gc" && -f "$gc" ]]; then go_local="$gc"; break; fi
    done

    if [[ -n "$go_local" ]]; then
        binfo "Using local Go package: $go_local" "使用本地 Go 安装包: $go_local"
        if ! cp -f "$go_local" "$go_tarball" || ! tar -tzf "$go_tarball" >/dev/null 2>&1; then
            berror "Local Go package invalid or corrupted: $go_local" "本地 Go 安装包无效或损坏: $go_local"
            exit 1
        fi
    else
        if [[ "$OFFLINE_MODE" == "true" ]]; then
            berror "Local Go package not found in offline mode. Place go${GO_VERSION}.linux-${go_arch}.tar.gz next to this script and rerun." \
                   "离线模式未找到本地 Go 安装包。请将 go${GO_VERSION}.linux-${go_arch}.tar.gz 放到脚本同目录后重新运行。"
            exit 1
        fi
        binfo "Downloading Go..." "正在下载 Go..."
        if ! curl -fL --connect-timeout 30 --max-time 300 --retry 3 --retry-delay 3 -C - "$go_url" -o "$go_tarball"; then
            bwarning "Official source failed, trying fallback..." "官方源下载失败，尝试备用源..."
            if ! curl -fL --connect-timeout 30 --max-time 300 --retry 3 --retry-delay 3 -C - "$fallback_url" -o "$go_tarball"; then
                berror "Go download failed. Install Go 1.21+ manually, or place go${GO_VERSION}.linux-${go_arch}.tar.gz next to this script and rerun." \
                       "Go 下载失败。请手动安装 Go 1.21+，或将 go${GO_VERSION}.linux-${go_arch}.tar.gz 放到脚本同目录后重新运行。"
                exit 1
            fi
        fi
    fi

    rm -rf /usr/local/go
    tar -C /usr/local -xzf "$go_tarball" || { berror "Go extraction failed" "Go 解压失败"; rm -f "$go_tarball"; exit 1; }
    rm -f "$go_tarball"
    echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
    export PATH="$PATH:/usr/local/go/bin"
    # 与 node 一致在 /usr/local/bin 建符号链接：run_step 已改用进程替换、明细模式下 export PATH 不再丢失，
    # 符号链接保留作为兼容兜底（菜单重编译等非登录 shell 场景仍可不依赖 profile）
    ln -sf /usr/local/go/bin/go /usr/local/bin/go
    ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
    bsuccess "Go installed ($(go version))" "Go 安装完成 ($(go version))"
}

install_nodejs() {
    if [[ "$PREBUILT_BINARY" == "true" ]]; then
        binfo "Binary delivery mode: skip Node.js install" "二进制交付模式：跳过 Node.js 安装"
        return 0
    fi
    local node_arch="x64"
    [[ $(uname -m) == "aarch64" ]] && node_arch="arm64"
    local node_local="" nc
    for nc in "${NODE_SRC_FILE:-}" "${SCRIPT_DIR}"/node-v*-linux-${node_arch}.tar.xz; do
        if [[ -n "$nc" && -f "$nc" ]]; then node_local="$nc"; break; fi
    done

    # 随包 Node 20 可用时优先安装它：离线 deb 包可能把系统发行版自带 node（如 Debian 12 的
    # Node 18）作为依赖装入，旧版 Node 默认堆上限小，vite build 容易 heap OOM；
    # 无随包 Node 且系统已有 >= 18 时才沿用系统版本。
    if [[ -z "$node_local" ]] && command -v node >/dev/null 2>&1; then
        local node_major
        node_major=$(node -v 2>/dev/null | grep -oP '\d+' | head -1)
        if [[ -n "$node_major" ]] && [[ "$node_major" -ge 18 ]]; then
            binfo "Node.js $(node -v) already installed ($(which node)), skipping" "Node.js $(node -v) 已安装 ($(which node))，跳过"
            return 0
        elif [[ -n "$node_major" ]]; then
            bwarning "Node.js $(node -v) too old (need >= 18), will update" "检测到 Node.js $(node -v) 版本过低（需要 >= 18），将更新"
        fi
    fi

    binfo "Installing Node.js 20.x..." "安装 Node.js 20.x..."

    # 优先使用本地离线 Node.js 官方二进制包（脚本同目录 node-v*-linux-<arch>.tar.xz，或 NODE_SRC_FILE 指定），
    # 避免 deb.nodesource.com / nodejs.org 在部分网络环境下失败。
    if [[ -n "$node_local" ]]; then
        binfo "Using local Node.js package: $node_local" "使用本地 Node.js 安装包: $node_local"
        if tar -tJf "$node_local" >/dev/null 2>&1; then
            rm -rf /usr/local/lib/nodejs && mkdir -p /usr/local/lib/nodejs
            if tar -C /usr/local/lib/nodejs -xJf "$node_local"; then
                local node_dir
                node_dir=$(find /usr/local/lib/nodejs -maxdepth 1 -type d -name "node-v*-linux-${node_arch}" | head -1)
                if [[ -n "$node_dir" && -x "$node_dir/bin/node" ]]; then
                    ln -sf "$node_dir/bin/node" /usr/local/bin/node
                    ln -sf "$node_dir/bin/npm" /usr/local/bin/npm
                    ln -sf "$node_dir/bin/npx" /usr/local/bin/npx
                    export PATH="$node_dir/bin:$PATH"
                    if command -v node >/dev/null 2>&1; then
                        bsuccess "Node.js installed ($(node -v))" "Node.js 安装完成 ($(node -v))"
                        return 0
                    fi
                fi
            fi
        fi
        bwarning "Local Node.js package invalid, falling back to online install..." "本地 Node.js 包无效，回退到在线安装..."
    fi

    if [[ "$OFFLINE_MODE" == "true" ]]; then
        berror "No usable local Node.js package in offline mode. Place node-v*-linux-x64.tar.xz next to this script and rerun." \
               "离线模式未找到可用的本地 Node.js 安装包。请将 node-v*-linux-x64.tar.xz 放到脚本同目录后重新运行。"
        exit 1
    fi

    if curl -fsSL --connect-timeout 10 https://deb.nodesource.com/setup_20.x | bash - 2>/dev/null; then
        apt-get install -y nodejs && bsuccess "Node.js installed ($(node -v))" "Node.js 安装完成 ($(node -v))" && return 0
    fi

    bwarning "NodeSource failed, trying nvm..." "NodeSource 安装失败，尝试使用 nvm 安装..."
    if command -v nvm >/dev/null 2>&1 || [[ -s "$HOME/.nvm/nvm.sh" ]]; then
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
        nvm install 20 && nvm use 20 && bsuccess "Node.js installed ($(node -v))" "Node.js 安装完成 ($(node -v))" && return 0
    fi

    bwarning "Trying default apt source for Node.js..." "尝试通过 apt 默认源安装 Node.js..."
    if apt-get install -y nodejs npm 2>/dev/null; then
        bsuccess "Node.js installed ($(node -v))" "Node.js 安装完成 ($(node -v))"
        return 0
    fi

    berror "Node.js installation failed, please install Node.js 18+ manually" "Node.js 安装失败，请手动安装 Node.js 18+ 后重试"
    exit 1
}

install_npm_deps() {
    binfo "Installing frontend dependencies..." "安装前端依赖..."
    cd "$1" || return 1

    # 随包 node_modules 可直接使用时跳过安装（离线安装的核心路径，避免任何 registry 联网）
    if frontend_deps_usable "$1"; then
        fix_node_bin_perms "$1"
        bsuccess "Bundled node_modules is usable, skip online install" "自带 node_modules 可用，跳过在线安装"
        return 0
    fi

    if [[ "$OFFLINE_MODE" == "true" ]]; then
        berror "Bundled node_modules unusable and no network in offline mode. Repack with Linux node_modules (see pack_offline_debs.sh)." \
               "自带 node_modules 不可用且离线模式无网络。请在 Linux 上重新打包 node_modules（参见 pack_offline_debs.sh）。"
        return 1
    fi

    local npm_flags="--no-audit --no-fund"

    if npm install $npm_flags --registry=https://registry.npmmirror.com; then
        fix_node_bin_perms "$1"
        bsuccess "Frontend dependencies installed" "前端依赖安装完成"
        return 0
    fi

    bwarning "Mirror failed, trying official source..." "淘宝镜像安装失败，尝试官方源..."
    if npm install $npm_flags; then
        fix_node_bin_perms "$1"
        bsuccess "Frontend dependencies installed" "前端依赖安装完成"
        return 0
    fi

    # package-lock.json 可能来自其他平台/其他 npm 版本，清理后重试
    bwarning "Retrying without package-lock.json..." "清理 package-lock.json 后重试安装..."
    rm -rf node_modules package-lock.json
    if npm install $npm_flags --registry=https://registry.npmmirror.com || npm install $npm_flags; then
        fix_node_bin_perms "$1"
        bsuccess "Frontend dependencies installed" "前端依赖安装完成"
        return 0
    fi

    berror "Frontend dependencies installation failed, installation aborted" "前端依赖安装失败，安装终止"
    exit 1
}

# zip/跨平台复制会丢失 Unix 可执行权限位，导致 "sh: 1: vite: Permission denied"
fix_node_bin_perms() {
    local dir="$1"
    [[ -d "$dir/node_modules" ]] || return 0
    chmod -R u+x "$dir/node_modules/.bin" 2>/dev/null || true
    find "$dir/node_modules" -type d -name bin -prune -exec chmod -R u+x {} + 2>/dev/null || true
    find "$dir/node_modules" -type f -name 'esbuild' -exec chmod u+x {} + 2>/dev/null || true
    return 0
}

# ===== 前端构建内存保障 =====
# 小内存机器（1~2GB）上 vite build 容易触发 "JavaScript heap out of memory"：
# 1) ensure_build_swap：总内存（物理+swap）不足 2GB 时临时创建 2GB swapfile 兜底，构建后由 release_build_swap 清理
# 2) NODE_BUILD_HEAP_MB：按可用内存动态设定 Node 堆上限，经 NODE_OPTIONS 注入构建命令
BUILD_SWAP_FILE=""   # 本次构建临时创建的 swapfile（成功创建才有值）
BUILD_SWAP_CREATED=""

ensure_build_swap() {
    local total_mb avail_swap_mb
    total_mb=$(free -m | awk '/^Mem:/{print $2}')
    avail_swap_mb=$(free -m | awk '/^Swap:/{print $2}')
    if [[ $((total_mb + avail_swap_mb)) -ge 2048 ]]; then
        return 0
    fi
    bwarning "Low memory (RAM ${total_mb}MB + swap ${avail_swap_mb}MB < 2GB), creating temporary 2GB swapfile for the frontend build..." \
             "内存偏低（物理 ${total_mb}MB + swap ${avail_swap_mb}MB 不足 2GB），为前端构建临时创建 2GB 交换文件..."
    BUILD_SWAP_FILE="/var/netglimmer-buildswap.swp"
    if { fallocate -l 2G "$BUILD_SWAP_FILE" 2>/dev/null || dd if=/dev/zero of="$BUILD_SWAP_FILE" bs=1M count=2048 status=none; } \
        && chmod 600 "$BUILD_SWAP_FILE" && mkswap "$BUILD_SWAP_FILE" >/dev/null 2>&1 && swapon "$BUILD_SWAP_FILE" 2>/dev/null; then
        BUILD_SWAP_CREATED="true"
        bsuccess "Temporary swap enabled: $BUILD_SWAP_FILE (auto-removed after build)" "临时交换已启用: $BUILD_SWAP_FILE（构建后自动清理）"
    else
        BUILD_SWAP_FILE=""
        bwarning "Failed to create temporary swap, build may still run out of memory" "临时交换创建失败，构建仍可能内存不足"
    fi
}

release_build_swap() {
    [[ "$BUILD_SWAP_CREATED" == "true" && -n "$BUILD_SWAP_FILE" ]] || return 0
    swapoff "$BUILD_SWAP_FILE" 2>/dev/null || true
    rm -f "$BUILD_SWAP_FILE" 2>/dev/null || true
    BUILD_SWAP_FILE=""
    BUILD_SWAP_CREATED=""
}

# 按物理内存+swap 总量动态设定 Node 堆上限（MB），供 NODE_OPTIONS=--max-old-space-size 使用。
# 上限 4096 避免无谓占用；有 swap 兜底时给足 2048，避免堆限小于构建实际需求导致 OOM。
node_build_heap_mb() {
    local total_mb heap
    total_mb=$(free -m | awk '/^Mem:/{print $2}')
    total_mb=$(( total_mb + $(free -m | awk '/^Swap:/{print $2}') ))
    heap=$(( total_mb * 3 / 4 ))
    [[ $heap -gt 4096 ]] && heap=4096
    [[ $heap -lt 1024 ]] && heap=1024
    echo "$heap"
}

# 校验 node_modules 是否可用于当前平台（跨平台打包的依赖必须重装）
frontend_deps_usable() {
    local dir="$1"
    local nm="$dir/node_modules"
    local p

    [[ -d "$nm" ]] || return 1
    [[ -f "$nm/vite/bin/vite.js" ]] || return 1

    # Windows npm 生成的 .cmd/.ps1 shim → node_modules 来自 Windows
    if [[ -e "$nm/.bin/vite.cmd" ]] || [[ -e "$nm/.bin/vite.ps1" ]]; then
        return 1
    fi

    # 存在 Windows / macOS 原生依赖 → node_modules 来自其他系统
    for p in "$nm"/@esbuild/win32-* "$nm"/@esbuild/darwin-* \
             "$nm"/@rollup/rollup-win32-* "$nm"/@rollup/rollup-darwin-*; do
        if [[ -e "$p" ]]; then
            return 1
        fi
    done

    # 缺少当前（Linux）平台 esbuild 原生二进制 → 不可用
    if [[ -d "$nm/esbuild" ]]; then
        local has_linux=0
        for p in "$nm"/@esbuild/linux-*; do
            if [[ -e "$p" ]]; then
                has_linux=1
            fi
        done
        if [[ "$has_linux" -ne 1 ]]; then
            return 1
        fi
    fi

    return 0
}

# 前端构建（带内存保障、权限修复与依赖重装兜底）
run_frontend_build() {
    local dir="$1"
    cd "$dir" || return 1

    fix_node_bin_perms "$dir"

    # 小内存机器上 vite build 易触发 JS 堆 OOM：临时 swap 兜底 + 按内存动态调高 Node 堆上限
    ensure_build_swap
    local heap_mb
    heap_mb=$(node_build_heap_mb)
    binfo "Frontend build memory guard: Node heap limit ${heap_mb}MB" "前端构建内存保障: Node 堆上限 ${heap_mb}MB"
    export NODE_OPTIONS="--max-old-space-size=${heap_mb}"

    local rc=0
    if npm run build; then
        release_build_swap
        return 0
    fi

    bwarning "npm run build failed, invoking vite directly..." "npm run build 失败，尝试直接调用 vite 构建..."
    fix_node_bin_perms "$dir"
    if [[ -f "$dir/node_modules/vite/bin/vite.js" ]] && node "$dir/node_modules/vite/bin/vite.js" build; then
        release_build_swap
        return 0
    fi

    if [[ "$OFFLINE_MODE" == "true" ]]; then
        release_build_swap
        berror "Frontend build failed and no network available in offline mode" "前端构建失败，离线模式下无法重装依赖"
        binfo "If the failure mentions 'heap out of memory', add swap (e.g. fallocate -l 2G /swapfile && mkswap /swapfile && swapon /swapfile) and rerun" \
              "若失败信息包含 heap out of memory（内存不足），请先增加 swap（如: fallocate -l 2G /swapfile && mkswap /swapfile && swapon /swapfile）后重试"
        return 1
    fi

    bwarning "Reinstalling frontend dependencies and rebuilding..." "仍然失败，清理并重装前端依赖后重新构建..."
    rm -rf "$dir/node_modules"
    install_npm_deps "$dir"
    cd "$dir" || rc=1
    if [[ $rc -eq 0 ]]; then
        fix_node_bin_perms "$dir"
        npm run build
        rc=$?
    fi
    release_build_swap
    return $rc
}

generate_certificates() {
    binfo "Generating self-signed SSL certificates..." "生成自签名 SSL 证书..."
    mkdir -p /etc/ocserv/ssl
    cd /etc/ocserv/ssl

    certtool --generate-privkey --outfile ca-key.pem 2>/dev/null

    cat > ca.tmpl <<EOF
cn = "Netglimmer VPN CA"
organization = "Netglimmer"
serial = 1
expiration_days = 3650
ca
signing_key
cert_signing_key
crl_signing_key
EOF
    certtool --generate-self-signed --load-privkey ca-key.pem --template ca.tmpl --outfile ca-cert.pem 2>/dev/null

    certtool --generate-privkey --outfile server-key.pem 2>/dev/null

    cat > server.tmpl <<EOF
cn = "${SERVER_ADDRESS}"
organization = "Netglimmer"
serial = 2
expiration_days = 3650
signing_key
encryption_key
tls_www_server
dns_name = "${SERVER_ADDRESS}"
ip_address = "${SERVER_ADDRESS}"
EOF
    certtool --generate-certificate --load-privkey server-key.pem \
        --load-ca-certificate ca-cert.pem --load-ca-privkey ca-key.pem \
        --template server.tmpl --outfile server-cert.pem 2>/dev/null

    chmod 600 ca-key.pem server-key.pem
    chmod 644 ca-cert.pem server-cert.pem

    # 证书管理目录（客户端证书 / 第三方信任 CA / 已吊销证书副本）
    mkdir -p clients trusted-cas revoked
    chmod 700 clients revoked
    chmod 755 trusted-cas

    # 生成初始空 CRL（供 ocserv crl 配置项引用，面板吊销证书后会自动重建）
    cat > crl.tmpl <<EOF
crl_next_update = 365
crl_number = $(date +%s)
EOF
    certtool --generate-crl --load-ca-privkey ca-key.pem \
        --load-ca-certificate ca-cert.pem --template crl.tmpl --outfile crl.pem 2>/dev/null
    rm -f crl.tmpl

    bsuccess "SSL certificates generated" "SSL 证书生成完成"
}

configure_ocserv() {
    binfo "Configuring VPN service..." "配置 VPN 服务..."
    [[ -f $OCSERV_CONF ]] && cp $OCSERV_CONF "${OCSERV_CONF}.bak"

    cat > $OCSERV_CONF <<EOF
# VPN 配置文件
# 自动生成于 $(date)
# 由 Netglimmer VPN Manager 管理

# 关闭ocserv原生的积分机制，走我们自定义的封禁机制
max-ban-score = 0          # 关闭IP积分封禁，不再提前拦截
min-reauth-time = 0
ban-reset-time = 0
rate-limit-ms = 300        # 仅保留请求限流，不封禁

auth = "plain[passwd=/etc/ocserv/ocpasswd]"

tcp-port = ${SERVER_PORT}
udp-port = ${SERVER_PORT}
# 默认双栈监听（:: 同时接收 IPv4 映射连接）；IPv6 开关由管理面板“VPN 设置”统一管理，
# 关闭 IPv6 时面板会将监听地址归一回 0.0.0.0 并移除 ipv6-network 行。
listen-host = ::

run-as-user = nobody
run-as-group = daemon

socket-file = /run/ocserv.socket

server-cert = ${SERVER_CERT}
server-key = ${SERVER_KEY}
ca-cert = ${CA_CERT}

# 客户端认证方式（二选一）由管理面板"VPN 设置"统一管理，默认仅用户名密码认证；
# 切换为"用户名密码+证书"时由面板改写 auth 行（先强制校验客户端证书，再校验用户名密码），
# 不使用 enable-auth（其语义为"任一方法即可登录"的混合认证）。

isolate-workers = ${ISOLATE_WORKERS}

max-clients = 128
max-same-clients = 3

keepalive = 240
dpd = 120
mobile-dpd = 120
switch-to-tcp-timeout = 30
idle-timeout = 0
mobile-idle-timeout = 0

tls-priorities = "NORMAL:%SERVER_PRECEDENCE:%COMPAT:-RSA:-VERS-SSL3.0:-ARCFOUR-128"

auth-timeout = 240
cookie-timeout = 300
rekey-time = 172800
rekey-method = ssl

use-occtl = true
pid-file = /run/ocserv.pid

device = vpns
predictable-ips = true

ipv4-network = ${CLIENT_NETWORK}
ipv4-netmask = ${CLIENT_NETMASK}

# IPv6 客户端网段（默认启用，管理面板可在“VPN 设置”中关闭或调整）
ipv6-network = fd00:1000::/64

EOF

    # CRL：文件存在才写入配置，防止 ocserv 因缺失 CRL 文件启动失败
    if [[ -f /etc/ocserv/ssl/crl.pem ]]; then
        echo "crl = /etc/ocserv/ssl/crl.pem" >> $OCSERV_CONF
        echo "" >> $OCSERV_CONF
    fi

    # 默认不向客户端推送 DNS：客户端 DNS 全部由管理面板配置完成
    # （域名放行开关启用时按组推送隧道网关；系统 DNS 由网络接口页「DNS 设置」管理）

    cat >> $OCSERV_CONF <<EOF
# 路由配置
EOF

    if [[ -n "$PUSH_ROUTES" ]]; then
        CLEANED_ROUTES=$(echo "$PUSH_ROUTES" | tr -d ' ')
        mkdir -p "$(dirname "$OCSERV_ROUTES")"
        > "$OCSERV_ROUTES"
        IFS=',' read -ra ROUTE_ARRAY <<< "$CLEANED_ROUTES"
        for route in "${ROUTE_ARRAY[@]}"; do
            if [[ -n "$route" ]] && [[ "$route" =~ ^[0-9.]+\/[0-9]+$ ]]; then
                echo "route = ${route}" >> $OCSERV_CONF
                echo "${route}" >> "$OCSERV_ROUTES"
            else
                bwarning "Ignoring malformed route: ${route}" "忽略格式错误的路由: ${route}"
            fi
        done
    else
        mkdir -p "$(dirname "$OCSERV_ROUTES")"
        > "$OCSERV_ROUTES"
    fi

    cat >> $OCSERV_CONF <<EOF

cisco-client-compat = true

dtls-psk = true
dtls-legacy = true

config-per-user = /etc/ocserv/config-per-user/
config-per-group = /etc/ocserv/config-per-group/

connect-script = /etc/ocserv/connect.sh
disconnect-script = /etc/ocserv/disconnect.sh

# 服务伪装（形态 A：不设 realm）：未带暗号的请求（如浏览器直连）返回 404，对外表现为普通 Web 服务器，不暴露 VPN。
# 合法客户端连接地址须为 https://域名:端口/?<暗号>（暗号以 URL 查询串形式放在 ? 之后，非路径段）。暗号可在管理面板「配置管理」中修改，不能为空。
camouflage = true
camouflage_secret = "netglimmer"
EOF

    # 登录横幅可通过环境变量 SERVER_BANNER 配置，默认置空（不写 banner 行）
    if [[ -n "${SERVER_BANNER:-}" ]]; then
        echo "banner = \"${SERVER_BANNER}\"" >> $OCSERV_CONF
    fi

    # ocserv connect/disconnect 钩子脚本：源码模式取自 backend/，二进制交付模式随包放在脚本目录顶层；
    # 两处都缺失时明确报错，避免生成指向不存在脚本的 ocserv.conf
    local connect_src="$SCRIPT_DIR/backend/connect.sh"
    local disconnect_src="$SCRIPT_DIR/backend/disconnect.sh"
    if [[ ! -f "$connect_src" && -f "$SCRIPT_DIR/connect.sh" ]]; then
        connect_src="$SCRIPT_DIR/connect.sh"
        disconnect_src="$SCRIPT_DIR/disconnect.sh"
    fi
    if [[ ! -f "$connect_src" || ! -f "$disconnect_src" ]]; then
        berror "connect.sh/disconnect.sh hook scripts not found" "未找到 connect.sh/disconnect.sh 钩子脚本"
        exit 1
    fi
    cp "$connect_src" /etc/ocserv/connect.sh
    cp "$disconnect_src" /etc/ocserv/disconnect.sh
    chmod +x /etc/ocserv/connect.sh /etc/ocserv/disconnect.sh

    bsuccess "VPN service configured" "VPN 服务配置完成"
}

configure_system() {
    binfo "Configuring system IP forwarding and firewall rules..." "配置系统 IP 转发和防火墙规则..."

    printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' > /etc/sysctl.d/60-ocserv.conf
    sysctl -p /etc/sysctl.d/60-ocserv.conf >/dev/null 2>&1

    MAIN_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    [[ -z "$MAIN_INTERFACE" ]] && MAIN_INTERFACE="eth0"
    binfo "Main network interface: $MAIN_INTERFACE" "主网卡接口: $MAIN_INTERFACE"

    local CLIENT_CIDR=$(netmask_to_cidr "${CLIENT_NETMASK}")
    local CLIENT_SUBNET="${CLIENT_NETWORK}/${CLIENT_CIDR}"

    binfo "Client subnet: ${CLIENT_SUBNET}" "客户端子网: ${CLIENT_SUBNET}"

    iptables -t nat -D POSTROUTING -s "${CLIENT_SUBNET}" -o "$MAIN_INTERFACE" -m comment --comment "ngnat:默认NAT" -j MASQUERADE 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s "${CLIENT_SUBNET}" -o "$MAIN_INTERFACE" -j MASQUERADE 2>/dev/null || true
    # 清理遗留的宽泛 FORWARD ACCEPT 规则（FORWARD 权限由 ocserv-manager 按资源精确管理）
    iptables -D FORWARD -s "${CLIENT_SUBNET}" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -d "${CLIENT_SUBNET}" -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -p tcp --dport "${SERVER_PORT}" -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -p udp --dport "${SERVER_PORT}" -j ACCEPT 2>/dev/null || true

    # 只添加 NAT MASQUERADE，不添加宽泛 FORWARD ACCEPT
    # FORWARD 规则由 ocserv-manager 启动时按用户组资源精确生成（含 catch-all DROP）
    # 默认 NAT 打上 ngnat 注释，使其在管理面板 NAT 规则页面可见且可手动删除
    iptables -t nat -A POSTROUTING -s "${CLIENT_SUBNET}" -o "$MAIN_INTERFACE" -m comment --comment "ngnat:默认NAT" -j MASQUERADE
    iptables -A INPUT -p tcp --dport "${SERVER_PORT}" -j ACCEPT
    iptables -A INPUT -p udp --dport "${SERVER_PORT}" -j ACCEPT

    if [[ "$ALLOW_CLIENT_INTERCONNECT" == "true" ]]; then
        iptables -D FORWARD -i vpns -o vpns -j ACCEPT 2>/dev/null || true
        iptables -A FORWARD -i vpns -o vpns -j ACCEPT
    fi

    ipset create "ocserv_blacklist" hash:ip timeout 172800 2>/dev/null || ipset flush "ocserv_blacklist"
    iptables -D INPUT -m set --match-set "ocserv_blacklist" src -j DROP 2>/dev/null || true
    iptables -I INPUT 1 -m set --match-set "ocserv_blacklist" src -j DROP
    # IPv6 自动封禁集合（family inet6，与 IPv4 集合相互独立）
    ipset create "ocserv_blacklist6" hash:ip family inet6 timeout 172800 2>/dev/null || ipset flush "ocserv_blacklist6"
    ip6tables -D INPUT -m set --match-set "ocserv_blacklist6" src -j DROP 2>/dev/null || true
    ip6tables -I INPUT 1 -m set --match-set "ocserv_blacklist6" src -j DROP

    # 手动黑名单集合（hash:net 支持 CIDR 网段，永久生效；条目由管理面板维护并在启动时重建）
    ipset create "netglimmer_manual_ban" hash:net maxelem 65536 2>/dev/null || true
    iptables -D INPUT -m set --match-set "netglimmer_manual_ban" src -j DROP 2>/dev/null || true
    iptables -I INPUT 1 -m set --match-set "netglimmer_manual_ban" src -j DROP
    # IPv6 手动黑名单集合（family inet6）
    ipset create "netglimmer_manual_ban6" hash:net family inet6 maxelem 65536 2>/dev/null || true
    ip6tables -D INPUT -m set --match-set "netglimmer_manual_ban6" src -j DROP 2>/dev/null || true
    ip6tables -I INPUT 1 -m set --match-set "netglimmer_manual_ban6" src -j DROP

    mkdir -p /etc/iptables
    ipset save > /etc/iptables/ipsets.v4 2>/dev/null || true
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true

    bsuccess "System configuration complete" "系统配置完成"
}

build_manager() {
    binfo "Building VPN management panel..." "编译 VPN 管理面板..."

    mkdir -p "$MANAGER_DIR"

    # ===== 预编译二进制交付模式：跳过全部编译，直接安装二进制 =====
    if [[ "$PREBUILT_BINARY" == "true" ]]; then
        binfo "Pre-built binary detected, skipping build (binary delivery mode)" \
              "检测到预编译二进制，跳过编译（二进制交付模式）"

        # HMAC 主密钥：复用优先级 /etc/.nglickey → ESP 镜像 → 首次随机生成（与编译模式一致）。
        # 发布版二进制运行时按同一优先级读取该文件，无需构建注入。
        local hmac_key_file="/etc/.nglickey"
        local hmac_key_esp="/boot/efi/EFI/NGSYS/.ngkey"
        local lic_hmac_key=""
        if [[ -s "$hmac_key_file" ]]; then
            lic_hmac_key=$(head -n1 "$hmac_key_file" | tr -d '[:space:]')
        fi
        if [[ -z "$lic_hmac_key" && -s "$hmac_key_esp" ]]; then
            lic_hmac_key=$(head -n1 "$hmac_key_esp" | tr -d '[:space:]')
            if [[ -n "$lic_hmac_key" ]]; then
                ( umask 077 && printf '%s\n' "$lic_hmac_key" > "$hmac_key_file" ) \
                    || { berror "Failed to restore license HMAC key from ESP" "从 ESP 恢复授权 HMAC 密钥失败"; exit 1; }
                binfo "Restored license HMAC key from ESP mirror" "已从 ESP 镜像恢复授权 HMAC 密钥"
            fi
        fi
        if [[ -z "$lic_hmac_key" ]]; then
            lic_hmac_key=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
            ( umask 077 && printf '%s\n' "$lic_hmac_key" > "$hmac_key_file" ) \
                || { berror "Failed to persist license HMAC key" "授权 HMAC 密钥持久化失败"; exit 1; }
            binfo "Generated new license HMAC key" "已生成新的授权 HMAC 密钥"
        else
            binfo "Reusing existing license HMAC key" "复用已有的授权 HMAC 密钥"
        fi
        chmod 600 "$hmac_key_file" 2>/dev/null || true
        # 同步镜像到 ESP（非 UEFI/未挂载 ESP 时静默跳过）
        if [[ ! -e "$hmac_key_esp" ]] || ! cmp -s "$hmac_key_file" "$hmac_key_esp"; then
            mkdir -p "$(dirname "$hmac_key_esp")" 2>/dev/null \
                && cp -f "$hmac_key_file" "$hmac_key_esp" 2>/dev/null \
                && chmod 600 "$hmac_key_esp" 2>/dev/null || true
        fi

        # 安装二进制：先复制为 .new 再 rename，避免覆盖运行中文件报 text file busy
        cp -f "$SCRIPT_DIR/ocserv-manager" "$MANAGER_DIR/ocserv-manager.new"
        chmod 755 "$MANAGER_DIR/ocserv-manager.new"
        mv -f "$MANAGER_DIR/ocserv-manager.new" "$MANAGER_DIR/ocserv-manager"

        bsuccess "Pre-built binary installed" "预编译二进制安装完成"
        return 0
    fi

    # ===== 前端构建 =====
    if [[ -d "$SCRIPT_DIR/frontend" ]]; then
        binfo "Building frontend..." "构建前端..."
        cd "$SCRIPT_DIR/frontend"

        # 随包 node_modules 可用则直接复用；不可用（跨平台打包/权限丢失）时才清理重装
        if [[ -d "node_modules" ]] && ! frontend_deps_usable "$SCRIPT_DIR/frontend"; then
            bwarning "Bundled node_modules not usable on this platform, reinstalling..." \
                     "检测到 node_modules 不适用于当前系统（跨平台打包或权限丢失），将重新安装前端依赖..."
            rm -rf "$SCRIPT_DIR/frontend/node_modules"
        fi

        # node_modules 缺失或不可用时安装依赖（install_npm_deps 内部会再次校验可用性）
        if ! frontend_deps_usable "$SCRIPT_DIR/frontend"; then
            install_npm_deps "$SCRIPT_DIR/frontend"
            cd "$SCRIPT_DIR/frontend"
        fi

        # 清理旧的 dist，确保用最新代码构建
        rm -rf "$SCRIPT_DIR/backend/dist"

        # 执行前端构建（含权限修复与依赖重装兜底）
        run_frontend_build "$SCRIPT_DIR/frontend" || { berror "Frontend build failed" "前端构建失败"; exit 1; }

        # 验证 dist 是否真正生成
        if [[ ! -f "$SCRIPT_DIR/backend/dist/index.html" ]]; then
            berror "Frontend dist not generated, check vite build output" "前端 dist 未生成，请检查 vite 构建输出"
            exit 1
        fi

        bsuccess "Frontend build complete" "前端构建完成"
    else
        # 没有前端源码，检查是否有预构建的 dist
        if [[ ! -f "$SCRIPT_DIR/backend/dist/index.html" ]]; then
            berror "Frontend directory not found and no pre-built dist exists" "未找到前端目录且无预构建 dist，无法继续"
            exit 1
        fi
        bwarning "Frontend source not found, using existing dist" "未找到前端源码，使用已有 dist"
    fi

    # ===== 后端编译 =====
    if [[ -d "$SCRIPT_DIR/backend" ]]; then
        binfo "Compiling Go backend..." "编译 Go 后端..."

        # run_step 已改用进程替换，明细模式下 install_go 步骤内的 export PATH 不再丢失；
        # 但菜单“重新编译面板”可能在未 source profile 的非登录 shell 中直接调用，此处仍自行补挂 PATH 兜底
        if ! command -v go >/dev/null 2>&1 && [[ -x /usr/local/go/bin/go ]]; then
            export PATH="$PATH:/usr/local/go/bin"
        fi
        if ! command -v go >/dev/null 2>&1; then
            berror "go command not found. Rerun install (Go step) or install Go 1.21+ manually" "未找到 go 命令，请重新执行安装（Go 步骤）或手动安装 Go 1.21+"
            exit 1
        fi

        if ! command -v gcc >/dev/null 2>&1; then
            binfo "Installing gcc (required for CGO)..." "安装 gcc (CGO 依赖)..."
            pkg_install gcc || { berror "gcc installation failed" "gcc 安装失败"; exit 1; }
        fi

        cd "$SCRIPT_DIR/backend"

        binfo "Preparing Go dependencies..." "准备 Go 依赖..."
        local go_mod_flags=""
        if [[ -d "vendor" ]]; then
            # vendor 随包分发：完全离线编译，不访问任何 Go 模块代理
            go_mod_flags="-mod=vendor"
            export GOPROXY=off
            binfo "Using bundled vendor directory (offline build)" "使用随包 vendor 目录（离线编译）"
        else
            # go.sum 不存在或 go.mod 有变更时都需要 tidy
            if [[ ! -f "go.sum" ]] || [[ "go.mod" -nt "go.sum" ]]; then
                if [[ "$OFFLINE_MODE" == "true" ]]; then
                    berror "vendor directory missing in offline mode. Run 'go mod vendor' on an online machine and repackage." \
                           "离线模式缺少 vendor 目录。请在联网机器执行 'go mod vendor' 后重新打包。"
                    exit 1
                fi
                GOPROXY="https://goproxy.cn,https://goproxy.io,https://proxy.golang.org,direct" go mod tidy \
                    || GOPROXY="https://proxy.golang.org,direct" go mod tidy \
                    || { berror "Go dependency download failed" "Go 依赖下载失败"; exit 1; }
            fi

            export GOPROXY="https://goproxy.cn,https://goproxy.io,https://proxy.golang.org,direct"
        fi

        # ===== 授权 HMAC 主密钥：每台部署机独立随机生成，构建时注入二进制 =====
        # 复用优先级：/etc/.nglickey → ESP 镜像（重装系统通常保留 ESP，可恢复原始密钥，
        # 保证重装前写入的锚定状态验签连续，试用/授权不被重装重置）→ 首次随机生成。
        hmac_key_file="/etc/.nglickey"
        hmac_key_esp="/boot/efi/EFI/NGSYS/.ngkey"
        lic_hmac_key=""
        if [[ -s "$hmac_key_file" ]]; then
            lic_hmac_key=$(head -n1 "$hmac_key_file" | tr -d '[:space:]')
        fi
        if [[ -z "$lic_hmac_key" && -s "$hmac_key_esp" ]]; then
            lic_hmac_key=$(head -n1 "$hmac_key_esp" | tr -d '[:space:]')
            if [[ -n "$lic_hmac_key" ]]; then
                ( umask 077 && printf '%s\n' "$lic_hmac_key" > "$hmac_key_file" ) \
                    || { berror "Failed to restore license HMAC key from ESP" "从 ESP 恢复授权 HMAC 密钥失败"; exit 1; }
                binfo "Restored license HMAC key from ESP mirror (reinstall detected)" "已从 ESP 镜像恢复授权 HMAC 密钥（检测到重装）"
            fi
        fi
        if [[ -z "$lic_hmac_key" ]]; then
            lic_hmac_key=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
            if [[ -z "$lic_hmac_key" ]]; then
                berror "Failed to generate license HMAC key" "授权 HMAC 密钥生成失败"; exit 1
            fi
            ( umask 077 && printf '%s\n' "$lic_hmac_key" > "$hmac_key_file" ) \
                || { berror "Failed to persist license HMAC key" "授权 HMAC 密钥持久化失败"; exit 1; }
            binfo "Generated new license HMAC key" "已生成新的授权 HMAC 密钥"
        else
            binfo "Reusing existing license HMAC key" "复用已有的授权 HMAC 密钥"
        fi
        chmod 600 "$hmac_key_file" 2>/dev/null || true
        # 同步镜像到 ESP（与后端 mirrorHMACKeyToESP 一致）：非 UEFI/未挂载 ESP 时静默跳过，
        # 保证下次重装系统（/etc/.nglickey 被清除）仍能从 ESP 恢复本密钥
        if [[ ! -e "$hmac_key_esp" ]] || ! cmp -s "$hmac_key_file" "$hmac_key_esp"; then
            mkdir -p "$(dirname "$hmac_key_esp")" 2>/dev/null \
                && cp -f "$hmac_key_file" "$hmac_key_esp" 2>/dev/null \
                && chmod 600 "$hmac_key_esp" 2>/dev/null || true
        fi

        CGO_ENABLED=1 go build $go_mod_flags \
            -ldflags="-s -w -X ocserv-manager/services.licenseHMACSecret=${lic_hmac_key}" \
            -o "$MANAGER_DIR/ocserv-manager.new" . \
            || { berror "Go build failed" "Go 编译失败"; exit 1; }
        # 先编译到临时文件再 mv 覆盖：直接 -o 覆盖正在运行的二进制会报 text file busy
        # （重装/重新编译时 ocserv-manager 可能仍在运行），rename 对运行中进程无影响
        mv -f "$MANAGER_DIR/ocserv-manager.new" "$MANAGER_DIR/ocserv-manager"

        bsuccess "Backend build complete ($(du -h "$MANAGER_DIR/ocserv-manager" | cut -f1))" \
                 "后端编译完成 ($(du -h "$MANAGER_DIR/ocserv-manager" | cut -f1))"
    else
        berror "Backend directory not found" "未找到后端目录"
        exit 1
    fi
}

setup_manager_service() {
    binfo "Configuring management panel service..." "配置管理面板服务..."

    # 读取系统当前时区，优先 /etc/timezone（Debian/Ubuntu），
    # 其次通过 timedatectl，最后兜底 Asia/Shanghai
    SYS_TZ=""
    if [ -f /etc/timezone ]; then
        SYS_TZ=$(cat /etc/timezone | tr -d '[:space:]')
    fi
    if [ -z "$SYS_TZ" ] && command -v timedatectl >/dev/null 2>&1; then
        SYS_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null | tr -d '[:space:]')
    fi
    if [ -z "$SYS_TZ" ]; then
        SYS_TZ="Asia/Shanghai"
    fi

    cat > "$MANAGER_SERVICE" <<EOF
[Unit]
Description=Netglimmer VPN Manager Panel
After=network.target ocserv.service
# 使用 Wants（弱依赖）而非 Requires：启动 manager 时带起 ocserv，
# 但当授权到期强制 systemctl stop ocserv 时不会连带停掉本面板（否则 /activate 也会不可访问，导致彻底锁死）。
Wants=ocserv.service

[Service]
Type=simple
ExecStart=${MANAGER_DIR}/ocserv-manager
Restart=always
RestartSec=5
Environment="PORT=8088"
Environment="DB_PATH=/etc/ocserv/ocserv-manager.db"
Environment="TZ=${SYS_TZ}"
Environment="TRUSTED_PROXY=true"

[Install]
WantedBy=multi-user.target
EOF

    binfo "Default admin: admin / netglimmer (changeable in Admin Management after login)" "默认管理员: admin / netglimmer (可登录后在「管理员管理」页面修改)"
    systemctl daemon-reload
    systemctl enable ocserv-manager
    systemctl restart ocserv-manager

    if systemctl is-active --quiet ocserv-manager; then
        bsuccess "Management panel service started" "管理面板服务启动成功"
    else
        berror "Management panel service failed to start, check: journalctl -u ocserv-manager -n 50" "管理面板服务启动失败，查看日志: journalctl -u ocserv-manager -n 50"
    fi
}

setup_nginx_https() {
    binfo "Configuring Nginx HTTPS reverse proxy..." "配置 Nginx HTTPS 反向代理..."

    # 安装 nginx 和 openssl
    DEBIAN_FRONTEND=noninteractive pkg_install nginx openssl 2>/dev/null \
        || { berror "Nginx/OpenSSL installation failed" "Nginx/OpenSSL 安装失败"; return 1; }

    # 生成自签名 SSL 证书
    mkdir -p "$NGINX_SSL_DIR"
    if [[ ! -f "$NGINX_SSL_CERT" ]]; then
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "$NGINX_SSL_KEY" \
            -out "$NGINX_SSL_CERT" \
            -subj "/C=CN/ST=Beijing/L=Beijing/O=Netglimmer/CN=${SERVER_ADDRESS}" 2>/dev/null
        chmod 600 "$NGINX_SSL_KEY"
        chmod 644 "$NGINX_SSL_CERT"
        bsuccess "Self-signed SSL certificate generated" "自签名 SSL 证书已生成"
    else
        binfo "SSL certificate already exists, skipping" "SSL 证书已存在，跳过生成"
    fi

    # 确定 HTTPS 端口（固定默认 8443，可通过 Web 管理页面修改）
    local HTTPS_PORT=8443
    binfo "HTTPS management panel will use port ${HTTPS_PORT}" "HTTPS 管理面板将使用 ${HTTPS_PORT} 端口"

    # 生成 nginx 配置文件
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    cat > "$NGINX_SITE_CONF" <<NGINX_EOF
# Netglimmer VPN Web 管理面板 HTTPS 反向代理
# 自动生成于 $(date)

server {
    listen 80;
    server_name ${SERVER_ADDRESS};
    return 301 https://\$host:${HTTPS_PORT}\$request_uri;
}

server {
    listen ${HTTPS_PORT} ssl;
    server_name ${SERVER_ADDRESS};

    # 隐藏 nginx 版本号，减少对外指纹暴露
    server_tokens off;

    ssl_certificate ${NGINX_SSL_CERT};
    ssl_certificate_key ${NGINX_SSL_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # 上传类接口体积放行（IP 归属地离线库 xdb 约 11MB、备份还原 zip 可达 100MB）；
    # nginx 默认仅 1MB，不放开时大文件在反代层即 413 拒绝，无法到达后端
    client_max_body_size 128m;

    # 内部接口仅供本机钩子/cron 直连 127.0.0.1:8088，禁止经反向代理对外暴露
    # （后端 RemoteAddr 检查在反代下会失效，此处在 nginx 层直接阻断）
    location /api/internal/ {
        deny all;
        return 403;
    }

    location / {
        proxy_pass http://127.0.0.1:8088;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400;
        proxy_buffering off;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
    }
}
NGINX_EOF

    # 启用站点
    ln -sf "$NGINX_SITE_CONF" /etc/nginx/sites-enabled/ocserv-panel
    rm -f /etc/nginx/sites-enabled/default

    # 测试配置
    if nginx -t 2>/dev/null; then
        systemctl enable nginx
        systemctl restart nginx
        bsuccess "Nginx HTTPS configured" "Nginx HTTPS 配置完成"
        binfo "HTTPS Panel: https://${SERVER_ADDRESS}:${HTTPS_PORT}" "HTTPS 管理面板: https://${SERVER_ADDRESS}:${HTTPS_PORT}"
        # 将 HTTPS 端口存入数据库，供 Web 管理页面读取和修改
        # ocserv-manager 启动后异步建表，此处轮询等待 system_settings 就绪，避免竞态导致写入丢失
        if command -v sqlite3 >/dev/null 2>&1; then
            local db_ready=false
            for _ in $(seq 1 30); do
                if [[ -f "$DB_PATH" ]] && sqlite3 "$DB_PATH" "SELECT 1 FROM system_settings LIMIT 1;" >/dev/null 2>&1; then
                    db_ready=true
                    break
                fi
                sleep 0.5
            done
            if [[ "$db_ready" == "true" ]] && sqlite3 "$DB_PATH" "INSERT OR REPLACE INTO system_settings (key, value) VALUES ('nginx_https_port', '${HTTPS_PORT}');" 2>/dev/null; then
                bsuccess "HTTPS port saved to database" "HTTPS 端口已写入数据库"
            else
                bwarning "Database not ready, HTTPS port not persisted (set it later in panel)" "数据库未就绪，HTTPS 端口未持久化（请稍后在面板中设置）"
            fi
        fi
    else
        berror "Nginx config test failed, check $NGINX_SITE_CONF" "Nginx 配置测试失败，请检查 $NGINX_SITE_CONF"
        return 1
    fi
}

interactive_install() {
    binfo "Starting interactive Netglimmer VPN installation..." "开始交互式安装 Netglimmer VPN..."
    echo ""

    binfo "=== Step 1/3: Server Address ===" "=== 步骤 1/3: 配置服务器地址 ==="
    local ip_list=$(get_server_ip)
    if [[ -n "$ip_list" ]]; then
        binfo "Detected IP addresses:" "检测到以下 IP 地址:"
        local i=1
        declare -a ip_array
        while IFS= read -r ip; do
            echo "  [$i] $ip"
            ip_array[$i]=$ip
            ((i++))
        done <<< "$ip_list"
        echo ""
        while true; do
            bread "Select server address [1] or enter domain/IP" "请选择服务器地址 [1] 或手动输入域名/IP" ""
            server_choice="$BREAD_RESULT"
            if [[ -z "$server_choice" ]]; then
                SERVER_ADDRESS="${ip_array[1]}"; break
            elif [[ "$server_choice" =~ ^[0-9]+$ ]] && [[ -n "${ip_array[$server_choice]}" ]]; then
                SERVER_ADDRESS="${ip_array[$server_choice]}"; break
            else
                is_valid_address "$server_choice" && { SERVER_ADDRESS="$server_choice"; break; }
                berror "Invalid address format, please try again" "输入的地址格式不正确，请重新输入"
            fi
        done
    else
        while true; do
            bread "Enter server address or domain" "请输入服务器地址或域名" ""
            SERVER_ADDRESS="$BREAD_RESULT"
            is_valid_address "$SERVER_ADDRESS" && break
            berror "Invalid address format, please try again" "输入的地址格式不正确，请重新输入"
        done
    fi
    bsuccess "Server address: $SERVER_ADDRESS" "服务器地址: $SERVER_ADDRESS"
    echo ""

    # 客户端互访默认启用（不再交互询问），如需隔离可在安装后由管理面板调整
    ALLOW_CLIENT_INTERCONNECT="true"
    ISOLATE_WORKERS="false"

    binfo "=== Step 2/3: Client IP Network ===" "=== 步骤 2/3: 配置客户端 IP 网段 ==="
    while true; do
        bread "Enter client IP network" "请输入客户端 IP 网段" "192.168.88.0/24"
        client_network="$BREAD_RESULT"
        if [[ -z "$client_network" ]]; then
            CLIENT_NETWORK="192.168.88.0"
            CLIENT_NETMASK="255.255.255.0"
            break
        elif is_valid_network "$client_network"; then
            local network_part=$(echo "$client_network" | cut -d'/' -f1)
            local cidr=$(echo "$client_network" | cut -d'/' -f2)
            if [ "$cidr" -lt 8 ] || [ "$cidr" -gt 30 ]; then
                berror "CIDR mask must be between 8-30" "CIDR 掩码必须在 8-30 之间"; continue
            fi
            CLIENT_NETWORK="$network_part"
            local mask=$((0xffffffff << (32 - cidr)))
            CLIENT_NETMASK="$(( (mask >> 24) & 0xff )).$(( (mask >> 16) & 0xff )).$(( (mask >> 8) & 0xff )).$(( mask & 0xff ))"
            break
        else
            berror "Invalid network format (e.g. 192.168.88.0/24)" "网段格式不正确 (例如: 192.168.88.0/24)"
        fi
    done
    bsuccess "Client network: ${CLIENT_NETWORK}/${CLIENT_NETMASK}" "客户端网段: ${CLIENT_NETWORK}/${CLIENT_NETMASK}"
    echo ""

    # DNS 服务器不再交互询问：客户端 DNS 全部由管理面板配置完成
    # （域名放行开关启用时按组推送隧道网关；系统 DNS 由网络接口页「DNS 设置」管理）

    binfo "=== Step 3/3: Server Port ===" "=== 步骤 3/3: 配置服务端口 ==="
    while true; do
        bread "Enter TCP/UDP port" "请输入 TCP/UDP 端口" "443"
        server_port="${BREAD_RESULT:-443}"
        if is_number "$server_port" && [ "$server_port" -gt 0 ] && [ "$server_port" -lt 65536 ]; then
            SERVER_PORT="$server_port"; break
        else
            berror "Port must be a number between 1-65535" "端口号必须是 1-65535 之间的数字"
        fi
    done
    bsuccess "Server port: $SERVER_PORT" "服务端口: $SERVER_PORT"
    echo ""

    binfo "=== Configuration Summary ===" "=== 配置摘要 ==="
    echo "  $(msg "Server Address" "服务器地址"): $SERVER_ADDRESS"
    echo "  $(msg "Client Network" "客户端网段"): ${CLIENT_NETWORK}/${CLIENT_NETMASK}"
    echo "  $(msg "Server Port" "服务端口"): $SERVER_PORT"
    echo "  $(msg "HTTPS Panel" "HTTPS 管理面板"): 8443"
    echo ""

    bread "Confirm and start installation? [Y/n]" "确认以上配置并开始安装? [Y/n]" ""
    confirm="$BREAD_RESULT"
    if [[ -n "$confirm" ]] && [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        bwarning "Installation cancelled" "安装已取消"
        exit 0
    fi

    echo ""
    binfo "==========================================" "=========================================="
    binfo "        Starting Netglimmer VPN Installation" "            开始安装 Netglimmer VPN"
    binfo "==========================================" "=========================================="
    echo ""

    local TOTAL_STEPS=10
    local INSTALL_START_TS=$(date +%s)
    : > "$INSTALL_LOG"  # 清空日志文件
    echo "[$(date '+%F %T')] Installation started / 安装开始" >> "$INSTALL_LOG"
    # 注册中断陷阱：Ctrl+C 等中断先清理后台步骤进程，再与步骤失败同样进入保护处理（重装场景自动回退）。
    # Ctrl+Z(TSTP) 同样按中断处理：否则脚本被挂起而 dpkg 继续运行/残留持锁，重跑会撞锁失败。
    trap 'on_install_interrupt INT' INT TERM
    trap 'on_install_interrupt TSTP' TSTP

    run_step 1 $TOTAL_STEPS "Install dependencies" "安装系统依赖" install_dependencies || { handle_install_failure; return 1; }
    run_step 2 $TOTAL_STEPS "Install Go" "安装 Go" install_go || { handle_install_failure; return 1; }
    run_step 3 $TOTAL_STEPS "Install Node.js" "安装 Node.js" install_nodejs || { handle_install_failure; return 1; }
    run_step 4 $TOTAL_STEPS "Generate certificates" "生成证书" generate_certificates || { handle_install_failure; return 1; }
    run_step 5 $TOTAL_STEPS "Configure VPN service" "配置 VPN 服务" configure_ocserv || { handle_install_failure; return 1; }
    run_step 6 $TOTAL_STEPS "Configure system" "配置系统" configure_system || { handle_install_failure; return 1; }
    run_step 7 $TOTAL_STEPS "Build management panel" "编译管理面板" build_manager || { handle_install_failure; return 1; }
    run_step 8 $TOTAL_STEPS "Start VPN service" "启动 VPN 服务" start_ocserv || { handle_install_failure; return 1; }
    run_step 9 $TOTAL_STEPS "Setup panel service" "配置面板服务" setup_manager_service || { handle_install_failure; return 1; }
    run_step 10 $TOTAL_STEPS "Setup Nginx HTTPS" "配置 Nginx HTTPS" setup_nginx_https || { handle_install_failure; return 1; }
    trap - INT TERM TSTP

    echo ""
    binfo "==========================================" "=========================================="
    bsuccess "Netglimmer VPN installation complete!" "Netglimmer VPN 安装完成!"
    binfo "==========================================" "=========================================="
    echo ""
    # 安装完成摘要卡片：总耗时 / 面板地址 / 初始账号 / 日志路径
    local total_elapsed=$(( $(date +%s) - INSTALL_START_TS ))
    local elapsed_text="$((total_elapsed / 60))m $((total_elapsed % 60))s"
    binfo "=== Installation Summary / 安装摘要 ===" "=== 安装摘要 ==="
    binfo "Total Time: $elapsed_text" "总耗时: $elapsed_text"
    if [[ "$OFFLINE_MODE" == "true" ]]; then
        binfo "Install Mode: fully offline" "安装模式: 完全离线"
    fi
    binfo "Server Port: $SERVER_PORT" "服务端口: $SERVER_PORT"
    # ocserv camouflage 暗号以 URL 查询串（? 之后）传递，展示为 https://域名[:端口]/?netglimmer
    # https 默认端口即 443，端口为 443 时省略 :443。
    if [ "$SERVER_PORT" = "443" ]; then
        CLIENT_ADDR="https://${SERVER_ADDRESS}/?netglimmer"
    else
        CLIENT_ADDR="https://${SERVER_ADDRESS}:${SERVER_PORT}/?netglimmer"
    fi
    binfo "Client Address: ${CLIENT_ADDR} (camouflage secret as URL query, after '?')" "客户端连接地址: ${CLIENT_ADDR} （已开启伪装，暗号以 URL 查询串形式放在 ? 之后，可在面板修改）"
    binfo "Panel URL: https://${SERVER_ADDRESS}:8443" "管理面板地址: https://${SERVER_ADDRESS}:8443"
    binfo "Default Admin: admin / netglimmer" "默认管理员: admin / netglimmer"
    binfo "Config File: $OCSERV_CONF" "配置文件: $OCSERV_CONF"
    binfo "Password File: $OCSERV_PASSWD" "密码文件: $OCSERV_PASSWD"
    binfo "Full install log: $INSTALL_LOG" "完整安装日志: $INSTALL_LOG"
    if [[ "$PRIOR_STATE" == "reinstall" && -n "$SNAPSHOT_DIR" ]]; then
        binfo "Pre-install snapshot: $SNAPSHOT_DIR (deletable after confirming new install is stable)" "安装前快照: $SNAPSHOT_DIR（确认新安装稳定后可删除）"
    fi
    echo ""
    bwarning "After login, please configure System DNS under DNS Settings on the Network Interfaces page (required for dynamic domain allowlisting)" "登录后请在「网络接口」页的 DNS 设置中配置系统 DNS（域名动态放行依赖）"
    echo ""
    binfo "Management Commands:" "管理命令:"
    binfo "  systemctl status ocserv-manager    # Check panel status / 查看面板状态" "  systemctl status ocserv-manager    # 查看面板状态"
    binfo "  systemctl restart ocserv-manager   # Restart panel / 重启面板" "  systemctl restart ocserv-manager   # 重启面板"
    binfo "  journalctl -u ocserv-manager -f    # View logs / 查看面板日志" "  journalctl -u ocserv-manager -f    # 查看面板日志"
    echo ""
}

install_ocserv() {
    check_root
    check_system

    # 安装模式由用户决定：--offline / OFFLINE_MODE 可显式强制，否则交互询问
    choose_install_mode

    # 判定是否重装（存在服务单元或配置目录即视为有历史安装），决定失败时是否自动回退
    if [[ -f "$MANAGER_SERVICE" || -f "$OCSERV_SERVICE" || -d /etc/ocserv ]]; then
        PRIOR_STATE="reinstall"
    else
        PRIOR_STATE="fresh"
    fi

    # 同时检测 ocserv 与 ocserv-manager：授权到期时 enforcer 会强制停掉 ocserv，
    # 若只检测 ocserv 会跳过重装确认，且面板运行中直接覆盖数据库/配置存在风险
    if systemctl is-active --quiet ocserv 2>/dev/null || systemctl is-active --quiet ocserv-manager 2>/dev/null; then
        bwarning "VPN service is already running" "检测到 VPN 服务或管理面板已在运行"
        bread "Reinstall? This will overwrite existing config [y/N]" "是否要重新安装? 这将会覆盖现有配置 [y/N]" ""
        reinstall="$BREAD_RESULT"
        if [[ ! "$reinstall" =~ ^[Yy]$ ]]; then
            binfo "Installation cancelled" "安装已取消"; exit 0
        fi
        # 先做全量快照再停服：安装失败/中断时可自动回退，避免生产服务停摆
        snapshot_existing_install
        binfo "Stopping existing services..." "停止现有服务..."
        systemctl stop ocserv ocserv-manager 2>/dev/null || true
        # 注意：此处不执行 disable，回退时按快照记录的自启状态恢复
    fi

    interactive_install
}

uninstall_ocserv() {
    check_root
    bwarning "About to uninstall Netglimmer VPN and all related configs" "即将卸载 Netglimmer VPN 及管理面板所有相关配置"
    bread "Confirm uninstall? [y/N]" "确认卸载? [y/N]" ""
    confirm="$BREAD_RESULT"

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        binfo "Uninstall cancelled" "卸载已取消"; exit 0
    fi

    binfo "Stopping all related services..." "停止所有相关服务..."
    systemctl stop ocserv ocserv-manager 2>/dev/null || true
    # dnsmasq 仅在由本脚本部署时才停用（以基础配置文件为凭），避免误伤用户自建的 dnsmasq 服务
    if [[ -f /etc/dnsmasq.d/ocserv-base.conf ]]; then
        systemctl stop dnsmasq 2>/dev/null || true
        systemctl disable dnsmasq 2>/dev/null || true
    fi
    systemctl disable ocserv ocserv-manager ocserv-web-api ocserv-log-monitor ocserv-ban-monitor 2>/dev/null || true

    # 第一时间导出授权状态到 /etc/.nglicense（停服后、任何删除动作前）：
    # 优先复用后端激活/续约时写入的三行备份（授权串/激活记录/nonce 清单，
    # 含续约叠加后的生效到期日）；仅旧版设备无三行备份时才从数据库导出授权串单行，
    # 重装后面板启动时验签通过即自动恢复激活状态（含续约状态与幂等清单）
    if [[ -f /etc/.nglicense ]] && [[ $(wc -l < /etc/.nglicense) -ge 3 ]]; then
        binfo "License backup (3-line) already in place (auto-restored on reinstall)" "授权三行备份已就位（重装后自动恢复激活与续约状态）"
    elif [[ -f "$DB_PATH" ]] && command -v sqlite3 >/dev/null 2>&1; then
        lic_blob=$(sqlite3 "$DB_PATH" "SELECT value FROM system_settings WHERE key='license_blob';" 2>/dev/null || true)
        if [[ -n "$lic_blob" ]]; then
            ( umask 077 && printf '%s\n' "$lic_blob" > /etc/.nglicense ) \
                && binfo "License exported to /etc/.nglicense (auto-restored on reinstall)" "授权已导出至 /etc/.nglicense（重装后自动恢复激活状态）"
        fi
    fi

    binfo "Removing service files..." "删除服务文件..."
    rm -f "$MANAGER_SERVICE"
    # 源码编译安装的 ocserv：先停服并移除自建 systemd unit
    systemctl stop ocserv 2>/dev/null || true
    systemctl disable ocserv 2>/dev/null || true
    rm -f "$OCSERV_SERVICE"
    rm -f /etc/systemd/system/ocserv-log-monitor.service
    rm -f /etc/systemd/system/ocserv-ban-monitor.service
    rm -f /etc/systemd/system/ocserv-web-api.service
    rm -f /etc/systemd/system/ipset-persistent.service
    rm -f /usr/local/bin/ocserv-log-monitor.sh
    rm -f /usr/local/bin/ocserv-ban-monitor.sh
    rm -f /usr/local/bin/ocserv-web-api-update.sh
    systemctl daemon-reload

    rm -rf "$MANAGER_DIR"

    binfo "Removing iptables rules and ipset..." "删除 iptables 规则和 ipset..."
    if [[ -f $OCSERV_CONF ]]; then
        local network=$(grep "^ipv4-network" $OCSERV_CONF | awk '{print $3}')
        local netmask=$(grep "^ipv4-netmask" $OCSERV_CONF | awk '{print $3}')
        local port=$(grep "^tcp-port" $OCSERV_CONF | awk '{print $3}')
        if [[ -n "$network" ]] && [[ -n "$netmask" ]]; then
            MAIN_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
            local cidr=$(netmask_to_cidr "${netmask}")
            local subnet="${network}/${cidr}"
            iptables -t nat -D POSTROUTING -s "${subnet}" -o "$MAIN_INTERFACE" -j MASQUERADE 2>/dev/null || true
            iptables -D FORWARD -s "${subnet}" -j ACCEPT 2>/dev/null || true
            iptables -D FORWARD -d "${subnet}" -j ACCEPT 2>/dev/null || true
            iptables -D FORWARD -i vpns -o vpns -j ACCEPT 2>/dev/null || true
            # 清理 ocserv-manager 运行时按用户组动态生成的 FORWARD 规则
            # （含 per-route ACCEPT 与 catch-all DROP，均引用客户端网段）
            iptables-save -t filter 2>/dev/null | grep '^-A FORWARD' | grep -F "${subnet}" | sed 's/^-A/-D/' | while read -r rule; do
                eval "iptables -t filter ${rule}" 2>/dev/null || true
            done
            # IPv6 镜像：v6 客户端网段的 FORWARD 规则（per-route ACCEPT / 互访 / catch-all DROP）
            local network6=$(grep "^ipv6-network" $OCSERV_CONF | awk '{print $3}')
            if [[ -n "$network6" ]]; then
                ip6tables -D FORWARD -s "${network6}" -j ACCEPT 2>/dev/null || true
                ip6tables -D FORWARD -d "${network6}" -j ACCEPT 2>/dev/null || true
                ip6tables-save -t filter 2>/dev/null | grep '^-A FORWARD' | grep -F "${network6}" | sed 's/^-A/-D/' | while read -r rule; do
                    eval "ip6tables -t filter ${rule}" 2>/dev/null || true
                done
            fi
        fi
        [[ -n "$port" ]] && {
            iptables -D INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null || true
            iptables -D INPUT -p udp --dport "${port}" -j ACCEPT 2>/dev/null || true
        }
    fi
    # 清理所有 vpns 接口相关 FORWARD 规则（客户端互访等，不依赖配置文件）
    iptables-save -t filter 2>/dev/null | grep '^-A FORWARD' | grep -- 'vpns' | sed 's/^-A/-D/' | while read -r rule; do
        eval "iptables -t filter ${rule}" 2>/dev/null || true
    done
    # 清理所有带 ngnat 注释的 NAT 规则（默认 NAT 与管理面板手动 NAT）
    iptables-save -t nat 2>/dev/null | grep '^-A POSTROUTING' | grep 'ngnat' | sed 's/^-A/-D/' | while read -r rule; do
        eval "iptables -t nat ${rule}" 2>/dev/null || true
    done
    # 清理管理面板维护的默认放行规则（netglimmer-default 注释标识：SSH/面板/VPN 端口，双族）
    for family_bin in iptables ip6tables; do
        ${family_bin}-save -t filter 2>/dev/null | grep '^-A INPUT' | grep 'netglimmer-default' | sed 's/^-A/-D/' | while read -r rule; do
            eval "${family_bin} -t filter ${rule}" 2>/dev/null || true
        done
    done
    # 循环删除防止重复规则残留（多次安装可能叠加）
    while iptables -C INPUT -m set --match-set "ocserv_blacklist" src -j DROP 2>/dev/null; do
        iptables -D INPUT -m set --match-set "ocserv_blacklist" src -j DROP 2>/dev/null || break
    done
    ipset destroy "ocserv_blacklist" 2>/dev/null || true
    while ip6tables -C INPUT -m set --match-set "ocserv_blacklist6" src -j DROP 2>/dev/null; do
        ip6tables -D INPUT -m set --match-set "ocserv_blacklist6" src -j DROP 2>/dev/null || break
    done
    ipset destroy "ocserv_blacklist6" 2>/dev/null || true
    while iptables -C INPUT -m set --match-set "netglimmer_manual_ban" src -j DROP 2>/dev/null; do
        iptables -D INPUT -m set --match-set "netglimmer_manual_ban" src -j DROP 2>/dev/null || break
    done
    ipset destroy "netglimmer_manual_ban" 2>/dev/null || true
    while ip6tables -C INPUT -m set --match-set "netglimmer_manual_ban6" src -j DROP 2>/dev/null; do
        ip6tables -D INPUT -m set --match-set "netglimmer_manual_ban6" src -j DROP 2>/dev/null || break
    done
    ipset destroy "netglimmer_manual_ban6" 2>/dev/null || true
    # 清理域名动态放行相关：引用 ocdom_* 集合的 FORWARD 规则 → 集合本身 → dnsmasq 配置
    iptables-save -t filter 2>/dev/null | grep '^-A FORWARD' | grep -- 'ocdom_' | sed 's/^-A/-D/' | while read -r rule; do
        eval "iptables -t filter ${rule}" 2>/dev/null || true
    done
    ipset list -n 2>/dev/null | grep '^ocdom_' | while read -r setname; do
        ipset destroy "$setname" 2>/dev/null || true
    done
    rm -f /etc/dnsmasq.d/ocserv-base.conf /etc/dnsmasq.d/ocserv-domains.conf
    rm -f /etc/iptables/ipsets.v4
    iptables-save > /etc/iptables/rules.v4
    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true

    binfo "Removing packages..." "卸载软件包..."
    # ocserv 为源码编译安装（非 apt），移除编译出的可执行文件；同时兼容历史 apt 安装的残留
    rm -f /usr/sbin/ocserv /usr/bin/occtl /usr/bin/ocpasswd \
          /usr/sbin/ocserv-worker /usr/sbin/ocserv-fw /usr/bin/ocserv-fw 2>/dev/null || true
    apt-get remove --purge -y ocserv jq ipset 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true

    binfo "Removing config files and logs..." "删除配置文件和日志..."
    rm -rf /etc/ocserv
    rm -rf /etc/ocserv-panel
    rm -f /etc/sysctl.d/60-ocserv.conf
    rm -f /etc/cron.d/ocserv-backup
    rm -rf /var/log/ocserv-sessions
    rm -rf "$BACKUP_ROOT"

    binfo "Removing Nginx configs..." "删除 Nginx 相关..."
    rm -rf /var/www/ocserv-panel
    rm -f /etc/nginx/sites-available/ocserv-panel
    rm -f /etc/nginx/sites-enabled/ocserv-panel
    if systemctl is-active --quiet nginx 2>/dev/null; then
        nginx -s reload 2>/dev/null || true
    fi

    # 可选：删除本脚本安装的构建工具链（Go / Node.js）。默认保留，避免影响其它项目。
    # 非交互场景（管道/EOF）下 read 失败时置空并继续，不因 set -e 中断卸载尾部流程
    bread "Also remove build toolchains (Go/Node.js) installed by this script? [y/N]" "是否同时删除本脚本安装的构建工具链（Go / Node.js）? [y/N]" "" || BREAD_RESULT=""
    if [[ "$BREAD_RESULT" =~ ^[Yy]$ ]]; then
        rm -rf /usr/local/go
        rm -f /etc/profile.d/go.sh
        # 仅当符号链接指向本脚本的安装目录时才移除，避免误删用户自装的 Go/Node
        for lnk in go gofmt; do
            if [[ "$(readlink /usr/local/bin/$lnk 2>/dev/null)" == /usr/local/go/* ]]; then
                rm -f "/usr/local/bin/$lnk"
            fi
        done
        for lnk in node npm npx; do
            if [[ "$(readlink -f /usr/local/bin/$lnk 2>/dev/null)" == /usr/local/lib/nodejs/* ]]; then
                rm -f "/usr/local/bin/$lnk"
            fi
        done
        rm -rf /usr/local/lib/nodejs
        binfo "Build toolchains removed" "构建工具链已删除"
    fi

    # 可选：卸载本脚本安装的系统软件包（nginx / dnsmasq / 编译依赖）。默认保留，
    # 避免影响机器上其它服务；ca-certificates / openssl / git 等通用包不列入，防止破坏系统依赖
    bread "Also remove system packages installed by this script (nginx, dnsmasq, build deps)? [y/N]" "是否同时卸载本脚本安装的系统包（nginx、dnsmasq、编译依赖等）? [y/N]" "" || BREAD_RESULT=""
    if [[ "$BREAD_RESULT" =~ ^[Yy]$ ]]; then
        apt-get remove --purge -y gnutls-bin iptables-persistent \
            build-essential pkg-config gperf xz-utils meson ninja-build \
            libgnutls28-dev nettle-dev libtasn1-6-dev libtasn1-bin \
            libev-dev libprotobuf-c-dev protobuf-c-compiler \
            libseccomp-dev libreadline-dev liblz4-dev libnl-route-3-dev libtalloc-dev libpam0g-dev \
            nginx dnsmasq gcc 2>/dev/null || true
        apt-get autoremove -y 2>/dev/null || true
        binfo "System packages removed" "系统软件包已卸载"
    fi

    # 授权相关隐藏文件（/etc/.nglickey、/etc/.nglicense、*/.ngsysid）有意保留：
    # ① 防卸载重装重置试用期；② 已激活设备重装后自动恢复授权状态。
    binfo "License markers preserved (trial clock & activation survive reinstall)" "授权标记文件已保留（试用进度与激活状态跨重装延续）"
    binfo "net.ipv4.ip_forward persistence removed; runtime value kept as-is (revert manually if needed)" "ip_forward 持久化配置已删除；运行时值保持现状（如需还原请手动 sysctl -w net.ipv4.ip_forward=0）"

    bsuccess "Netglimmer VPN uninstalled" "Netglimmer VPN 卸载完成"
}

create_user() {
    echo ""
    print_info "=== Create User / 创建新用户 ==="
    read -p "Username: " username
    [[ -z "$username" ]] && { print_error "Username cannot be empty / 用户名不能为空"; return 1; }
    if [[ -f $OCSERV_PASSWD ]] && grep -q "^${username}:" $OCSERV_PASSWD; then
        print_error "User $username already exists / 用户已存在"; return 1
    fi
    mkdir -p /etc/ocserv/config-per-user/
    mkdir -p /etc/ocserv/config-per-group/
    mkdir -p "$(dirname "$OCSERV_PASSWD")"
    touch "$OCSERV_PASSWD"
    ocpasswd -c "$OCSERV_PASSWD" "$username"
    if [[ $? -eq 0 ]]; then
        print_success "User $username created / 用户创建成功"
        systemctl is-active --quiet ocserv && systemctl reload ocserv
    else
        print_error "User creation failed / 用户创建失败"
    fi
}

start_ocserv() {
    binfo "Starting VPN service..." "启动 VPN 服务..."
    systemctl daemon-reload
    systemctl enable ocserv
    systemctl restart ocserv

    if systemctl is-active --quiet ocserv; then
        bsuccess "VPN service started" "VPN 服务启动成功"
    else
        berror "VPN service failed to start" "VPN 服务启动失败"
        binfo "Check logs: journalctl -u ocserv -n 50" "查看日志: journalctl -u ocserv -n 50"
    fi
}

user_management() {
    while true; do
        echo ""
        print_info "========== User Management / 用户管理 =========="
        echo "1. Create User    / 创建用户"
        echo "2. Delete User    / 删除用户"
        echo "3. List Users     / 列出所有用户"
        echo "4. Service Status / 查看服务状态"
        echo "0. Back           / 返回上级菜单"
        echo ""
        read -p "Select [0-4]: " choice
        case $choice in
            1) create_user ;;
            2)
                echo ""
                print_info "=== Delete User / 删除用户 ==="
                if [[ ! -f $OCSERV_PASSWD ]] || [[ ! -s $OCSERV_PASSWD ]]; then
                    print_warning "No users to delete / 没有可删除的用户"; continue
                fi
                print_info "Current user list / 当前用户列表:"
                local i=1
                declare -a user_array
                while IFS=: read -r user _; do
                    echo "  [$i] $user"
                    user_array[$i]=$user
                    ((i++))
                done < "$OCSERV_PASSWD"
                echo ""
                read -p "Select user number [1-$((i-1))]: " user_num
                if [[ ! "$user_num" =~ ^[0-9]+$ ]] || [[ -z "${user_array[$user_num]}" ]]; then
                    print_error "Invalid selection / 无效的选择"; continue
                fi
                local del_user="${user_array[$user_num]}"
                read -p "Confirm delete user $del_user? [y/N]: " confirm
                if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                    print_info "Cancelled / 操作已取消"; continue
                fi
                sed -i "/^${del_user}:/d" "$OCSERV_PASSWD"
                rm -f "/etc/ocserv/config-per-user/${del_user}"
                occtl disconnect user "${del_user}" 2>/dev/null || true
                print_success "User $del_user deleted / 用户已删除"
                systemctl is-active --quiet ocserv && systemctl reload ocserv
                ;;
            3)
                echo ""
                print_info "=== User List / 用户列表 ==="
                if [[ ! -f $OCSERV_PASSWD ]] || [[ ! -s $OCSERV_PASSWD ]]; then
                    print_warning "No users found / 没有找到用户"
                else
                    printf "%-20s\n" "Username"
                    echo "--------------------"
                    while IFS=: read -r user _; do printf "%-20s\n" "$user"; done < "$OCSERV_PASSWD"
                fi
                ;;
            4) systemctl status ocserv ;;
            0) break ;;
            *) print_error "Invalid selection / 无效的选择" ;;
        esac
    done
}

ban_management() {
    while true; do
        echo ""
        print_info "========== Ban Management / 封禁管理 =========="
        echo "1. View Banned IPs / 查看封禁列表"
        echo "2. Unban IP        / 解除封禁"
        echo "0. Back            / 返回上级菜单"
        echo ""
        read -p "Select [0-2]: " choice
        case $choice in
            1)
                echo ""
                print_info "=== Banned IP List / 封禁列表 ==="
                if ipset list ocserv_blacklist >/dev/null 2>&1; then
                    local ban_list=$(ipset list ocserv_blacklist | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
                    if [[ -n "$ban_list" ]]; then
                        printf "%-20s %-20s\n" "IP Address" "Remaining / 剩余时间"
                        echo "----------------------------------------"
                        echo "$ban_list" | while read -r ip_entry; do
                            if [[ "$ip_entry" =~ ^([0-9.]+)[[:space:]]+timeout[[:space:]]+([0-9]+) ]]; then
                                local ip="${BASH_REMATCH[1]}"
                                local timeout="${BASH_REMATCH[2]}"
                                local hours=$((timeout / 3600))
                                local minutes=$(((timeout % 3600) / 60))
                                printf "%-20s %-20s\n" "$ip" "${hours}h ${minutes}m"
                            elif [[ "$ip_entry" =~ ^([0-9.]+) ]]; then
                                local ip="${BASH_REMATCH[1]}"
                                printf "%-20s %-20s\n" "$ip" "Permanent / 永久封禁"
                            fi
                        done
                    else
                        print_info "No banned IPs / 当前没有被封禁的 IP"
                    fi
                else
                    print_error "Cannot read ban list / 无法读取封禁列表"
                fi
                ;;
            2)
                echo ""
                print_info "=== Unban IP / 解除封禁 ==="
                if ipset list ocserv_blacklist >/dev/null 2>&1; then
                    local current_bans=($(ipset list ocserv_blacklist | grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | awk '{print $1}'))
                    if [[ ${#current_bans[@]} -eq 0 ]]; then
                        print_info "No banned IPs / 当前没有被封禁的 IP"
                    else
                        echo "Select IP to unban (number or IP) / 请选择要解封的 IP:"
                        local idx=0
                        for ip in "${current_bans[@]}"; do
                            idx=$((idx + 1))
                            printf "  [%d] %s\n" "$idx" "$ip"
                        done
                        echo ""
                        read -p "Input [number/IP]: " unban_input
                        local target_ip=""
                        if [[ "$unban_input" =~ ^[0-9]+$ ]] && [[ "$unban_input" -le ${#current_bans[@]} ]] && [[ "$unban_input" -gt 0 ]]; then
                            target_ip="${current_bans[$((unban_input - 1))]}"
                        else
                            target_ip="$unban_input"
                        fi
                        if [[ -n "$target_ip" ]]; then
                            if ipset del ocserv_blacklist "$target_ip" 2>/dev/null; then
                                print_success "IP $target_ip unbanned / 已解封"
                            else
                                print_error "Unban failed / 解封失败"
                            fi
                        fi
                    fi
                else
                    print_error "Cannot read ban list / 无法读取封禁列表"
                fi
                ;;
            0) break ;;
            *) print_error "Invalid selection / 无效的选择" ;;
        esac
    done
}

service_management() {
    while true; do
        echo ""
        print_info "========== Service Management / 服务管理 =========="
        echo "1. Start           / 启动服务"
        echo "2. Stop            / 停止服务"
        echo "3. Restart         / 重启服务"
        echo "4. Status          / 查看服务状态"
        echo "5. View Logs       / 查看服务日志"
        echo "6. Restart Panel   / 重启管理面板"
        echo "0. Back            / 返回上级菜单"
        echo ""
        read -p "Select [0-6]: " choice
        case $choice in
            1) start_ocserv ;;
            2) systemctl stop ocserv; print_success "Service stopped / 服务已停止" ;;
            3) systemctl restart ocserv; print_success "Service restarted / 服务已重启" ;;
            4) systemctl status ocserv ;;
            5) journalctl -u ocserv -n 50 ;;
            6) systemctl restart ocserv-manager; print_success "Panel restarted / 管理面板已重启" ;;
            0) break ;;
            *) print_error "Invalid selection / 无效的选择" ;;
        esac
    done
}

# ── 数据库辅助 ──

db_query() {
    sqlite3 -header -column "$DB_PATH" "$1" 2>/dev/null
}

db_query_csv() {
    sqlite3 -csv "$DB_PATH" "$1" 2>/dev/null
}

check_db() {
    if [[ ! -f "$DB_PATH" ]]; then
        print_error "数据库不存在: $DB_PATH"
        print_info "请先执行安装 (选项 1) 以初始化数据库"
        return 1
    fi
    if ! command -v sqlite3 >/dev/null 2>&1; then
        print_error "sqlite3 未安装，请执行: apt-get install -y sqlite3"
        return 1
    fi
    return 0
}

# ── 资源管理 ──

resource_management() {
    while true; do
        echo ""
        print_info "========== 资源管理 / Resource Management =========="
        echo "1. List Resources    / 查看资源列表"
        echo "2. Create Resource   / 创建资源"
        echo "3. Delete Resource   / 删除资源"
        echo "0. Back              / 返回上级菜单"
        echo ""
        read -p "Select [0-3]: " choice
        case $choice in
            1)
                echo ""
                print_info "=== 资源列表 ==="
                check_db || continue
                local count=$(db_query_csv "SELECT COUNT(*) FROM resources;")
                if [[ "$count" == "0" ]]; then
                    print_warning "暂无资源"
                else
                    db_query "SELECT id, name, type, value, description FROM resources ORDER BY id;"
                fi
                ;;
            2)
                echo ""
                print_info "=== 创建资源 ==="
                check_db || continue
                read -p "资源名称 (如: 内网网段): " res_name
                [[ -z "$res_name" ]] && { print_error "名称不能为空"; continue; }

                echo "资源类型:"
                echo "  1) cidr   (IP 网段, 如 10.0.0.0/8)"
                echo "  2) domain (域名, 如 example.com)"
                read -p "选择类型 [1]: " type_choice
                local res_type="cidr"
                [[ "$type_choice" == "2" ]] && res_type="domain"

                read -p "资源值 (如 10.0.0.0/8 或 example.com): " res_value
                [[ -z "$res_value" ]] && { print_error "值不能为空"; continue; }

                # 格式校验
                if [[ "$res_type" == "cidr" ]]; then
                    if ! [[ "$res_value" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; then
                        print_error "无效的 CIDR 格式: $res_value"
                        continue
                    fi
                elif [[ "$res_type" == "domain" ]]; then
                    if ! [[ "$res_value" =~ ^(\*\.)?([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
                        print_error "无效的域名格式: $res_value"
                        continue
                    fi
                fi

                read -p "描述 (可选): " res_desc

                local now=$(date '+%Y-%m-%d %H:%M:%S')
                db_query "INSERT INTO resources (name, type, value, description, created_at) VALUES ('${res_name}', '${res_type}', '${res_value}', '${res_desc}', '${now}');"
                if [[ $? -eq 0 ]]; then
                    print_success "资源 '$res_name' ($res_type: $res_value) 创建成功"
                    restart_manager_if_running
                else
                    print_error "创建失败"
                fi
                ;;
            3)
                echo ""
                print_info "=== 删除资源 ==="
                check_db || continue
                local count=$(db_query_csv "SELECT COUNT(*) FROM resources;")
                if [[ "$count" == "0" ]]; then
                    print_warning "暂无资源可删除"
                    continue
                fi
                db_query "SELECT id, name, type, value FROM resources ORDER BY id;"
                echo ""
                read -p "输入要删除的资源 ID: " res_id
                [[ -z "$res_id" ]] && continue
                if ! [[ "$res_id" =~ ^[0-9]+$ ]]; then
                    print_error "无效的 ID"
                    continue
                fi
                # 先删除关联的组资源，再删除资源
                db_query "DELETE FROM user_group_resources WHERE resource_id=$res_id;"
                db_query "DELETE FROM resources WHERE id=$res_id;"
                if [[ $? -eq 0 ]]; then
                    print_success "资源 ID=$res_id 已删除"
                    restart_manager_if_running
                else
                    print_error "删除失败"
                fi
                ;;
            0) break ;;
            *) print_error "无效的选择" ;;
        esac
    done
}

# ── 用户组管理 ──

group_management() {
    while true; do
        echo ""
        print_info "========== 用户组管理 / Group Management =========="
        echo "1. List Groups       / 查看用户组列表"
        echo "2. Create Group      / 创建用户组"
        echo "3. Delete Group      / 删除用户组"
        echo "4. Assign Resources  / 为用户组分配资源"
        echo "5. List Members      / 查看用户组成员"
        echo "6. Bind Users        / 将用户绑定到用户组"
        echo "0. Back              / 返回上级菜单"
        echo ""
        read -p "Select [0-6]: " choice
        case $choice in
            1)
                echo ""
                print_info "=== 用户组列表 ==="
                check_db || continue
                db_query "SELECT g.id, g.name, g.description,
                    (SELECT COUNT(*) FROM user_group_resources WHERE group_id=g.id) AS resources,
                    (SELECT COUNT(*) FROM users WHERE group_id=g.id) AS members
                    FROM user_groups g ORDER BY g.id;"
                ;;
            2)
                echo ""
                print_info "=== 创建用户组 ==="
                check_db || continue
                read -p "组名 (如: dev-team): " group_name
                [[ -z "$group_name" ]] && { print_error "组名不能为空"; continue; }
                read -p "描述 (可选): " group_desc
                local now=$(date '+%Y-%m-%d %H:%M:%S')
                db_query "INSERT INTO user_groups (name, description, created_at) VALUES ('${group_name}', '${group_desc}', '${now}');"
                if [[ $? -eq 0 ]]; then
                    print_success "用户组 '$group_name' 创建成功"
                    restart_manager_if_running
                else
                    print_error "创建失败（组名可能已存在）"
                fi
                ;;
            3)
                echo ""
                print_info "=== 删除用户组 ==="
                check_db || continue
                db_query "SELECT id, name, description FROM user_groups ORDER BY id;"
                echo ""
                read -p "输入要删除的用户组 ID (default 组不可删除): " group_id
                [[ -z "$group_id" ]] && continue
                if ! [[ "$group_id" =~ ^[0-9]+$ ]]; then
                    print_error "无效的 ID"
                    continue
                fi
                local default_id=$(db_query_csv "SELECT id FROM user_groups WHERE name='default' LIMIT 1;")
                if [[ "$group_id" == "$default_id" ]]; then
                    print_error "不能删除默认用户组"
                    continue
                fi
                # 将组内用户迁移到 default 组
                db_query "UPDATE users SET group_id=$default_id WHERE group_id=$group_id;"
                db_query "DELETE FROM user_group_resources WHERE group_id=$group_id;"
                db_query "DELETE FROM user_groups WHERE id=$group_id;"
                if [[ $? -eq 0 ]]; then
                    print_success "用户组 ID=$group_id 已删除，成员已迁移到 default 组"
                    restart_manager_if_running
                else
                    print_error "删除失败"
                fi
                ;;
            4)
                echo ""
                print_info "=== 为用户组分配资源 ==="
                check_db || continue
                # 显示组列表
                db_query "SELECT id, name FROM user_groups ORDER BY id;"
                echo ""
                read -p "选择用户组 ID: " group_id
                [[ -z "$group_id" ]] && continue
                if ! [[ "$group_id" =~ ^[0-9]+$ ]]; then
                    print_error "无效的 ID"; continue
                fi
                # 显示当前分配的资源
                echo ""
                print_info "当前已分配的资源:"
                local current=$(db_query_csv "SELECT resource_id FROM user_group_resources WHERE group_id=$group_id;")
                if [[ -z "$current" ]]; then
                    echo "  (无)"
                else
                    db_query "SELECT r.id, r.name, r.type, r.value FROM resources r
                        INNER JOIN user_group_resources ugr ON r.id=ugr.resource_id
                        WHERE ugr.group_id=$group_id ORDER BY r.id;"
                fi
                # 显示所有可用资源
                echo ""
                print_info "所有可用资源 (输入 ID 列表，逗号分隔，留空则清空):"
                db_query "SELECT id, name, type, value FROM resources ORDER BY id;"
                echo ""
                read -p "资源 ID 列表 (如: 1,3,5): " res_ids
                # 清空旧关联
                db_query "DELETE FROM user_group_resources WHERE group_id=$group_id;"
                # 插入新关联
                if [[ -n "$res_ids" ]]; then
                    for rid in $(echo "$res_ids" | tr ',' ' '); do
                        rid=$(echo "$rid" | tr -d ' ')
                        if [[ "$rid" =~ ^[0-9]+$ ]]; then
                            db_query "INSERT OR IGNORE INTO user_group_resources (group_id, resource_id) VALUES ($group_id, $rid);"
                        fi
                    done
                fi
                print_success "资源分配已更新"
                restart_manager_if_running
                ;;
            5)
                echo ""
                print_info "=== 查看用户组成员 ==="
                check_db || continue
                db_query "SELECT id, name FROM user_groups ORDER BY id;"
                echo ""
                read -p "选择用户组 ID: " group_id
                [[ -z "$group_id" ]] && continue
                if ! [[ "$group_id" =~ ^[0-9]+$ ]]; then
                    print_error "无效的 ID"; continue
                fi
                echo ""
                local members=$(db_query_csv "SELECT COUNT(*) FROM users WHERE group_id=$group_id;")
                if [[ "$members" == "0" ]]; then
                    print_warning "该组暂无成员"
                else
                    db_query "SELECT username, email, created_at FROM users WHERE group_id=$group_id ORDER BY username;"
                fi
                ;;
            6)
                echo ""
                print_info "=== 将用户绑定到用户组 ==="
                check_db || continue
                # 显示组列表
                db_query "SELECT id, name FROM user_groups ORDER BY id;"
                echo ""
                read -p "目标用户组 ID: " group_id
                [[ -z "$group_id" ]] && continue
                if ! [[ "$group_id" =~ ^[0-9]+$ ]]; then
                    print_error "无效的 ID"; continue
                fi
                # 验证组存在
                local gname=$(db_query_csv "SELECT name FROM user_groups WHERE id=$group_id;")
                if [[ -z "$gname" ]]; then
                    print_error "用户组不存在"; continue
                fi
                # 显示所有用户及其当前组
                echo ""
                print_info "用户列表 (当前组 -> 目标组: $gname):"
                db_query "SELECT u.username, COALESCE(g.name,'-') as current_group
                    FROM users u LEFT JOIN user_groups g ON u.group_id=g.id
                    ORDER BY u.username;"
                echo ""
                read -p "输入用户名 (多个用逗号分隔): " usernames
                [[ -z "$usernames" ]] && continue
                local count=0
                for uname in $(echo "$usernames" | tr ',' ' '); do
                    uname=$(echo "$uname" | tr -d ' ')
                    if [[ -n "$uname" ]]; then
                        db_query "UPDATE users SET group_id=$group_id WHERE username='$uname';"
                        if [[ $? -eq 0 ]]; then
                            ((count++))
                        fi
                    fi
                done
                print_success "$count 个用户已绑定到组 '$gname'"
                restart_manager_if_running
                ;;
            0) break ;;
            *) print_error "无效的选择" ;;
        esac
    done
}

reset_admin_password() {
    echo ""
    print_info "=== Reset Admin Password / 重置管理员密码 ==="
    check_db || return 1

    # 确认操作
    bread "Reset admin password to netglimmer? [y/N]" "确认将 admin 用户密码重置为 netglimmer? [y/N]" ""
    confirm="$BREAD_RESULT"
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        binfo "Operation cancelled" "操作已取消"
        return 0
    fi

    # 生成 bcrypt hash：优先复用已编译的 ocserv-manager 二进制（无需联网/临时编译），再回退 Go/Python3
    local bcrypt_hash=""
    local MANAGER_BIN="${MANAGER_DIR}/ocserv-manager"
    if [[ -x "$MANAGER_BIN" ]]; then
        bcrypt_hash=$("$MANAGER_BIN" --hash-password "netglimmer" 2>/dev/null)
    fi
    if [[ -z "$bcrypt_hash" ]] && command -v go >/dev/null 2>&1; then
        local tmp_dir=$(mktemp -d)
        cat > "${tmp_dir}/main.go" <<'GOEOF'
package main

import (
	"fmt"
	"golang.org/x/crypto/bcrypt"
)

func main() {
	hash, err := bcrypt.GenerateFromPassword([]byte("netglimmer"), bcrypt.DefaultCost)
	if err != nil {
		panic(err)
	}
	fmt.Print(string(hash))
}
GOEOF
        cat > "${tmp_dir}/go.mod" <<'MODEOF'
module hashgen

go 1.21

require golang.org/x/crypto v0.32.0
MODEOF
        cd "${tmp_dir}"
        GOPROXY="https://goproxy.cn,https://goproxy.io,direct" go mod tidy 2>/dev/null
        bcrypt_hash=$(go run main.go 2>/dev/null)
        cd - >/dev/null
        rm -rf "${tmp_dir}"
    fi

    if [[ -z "$bcrypt_hash" ]]; then
        # 回退：使用 Python3 生成 bcrypt hash
        if command -v python3 >/dev/null 2>&1; then
            bcrypt_hash=$(python3 -c "
import hashlib, base64, os
try:
    import bcrypt
    print(bcrypt.hashpw(b'netglimmer', bcrypt.gensalt()).decode())
except ImportError:
    # 回退到 passlib
    try:
        from passlib.hash import bcrypt
        print(bcrypt.using(rounds=10).hash('netglimmer'))
    except ImportError:
        print('')
" 2>/dev/null)
        fi
    fi

    if [[ -z "$bcrypt_hash" ]]; then
        berror "Cannot generate password hash (build the panel first, or install Go / Python3+bcrypt)" "无法生成密码哈希（请先编译面板，或安装 Go / Python3+bcrypt）"
        binfo "Try: menu option 8 (Rebuild Panel), or pip3 install bcrypt" "可尝试：菜单选项 8（重新编译面板），或 pip3 install bcrypt"
        return 1
    fi

    # 更新数据库
    sqlite3 "$DB_PATH" "UPDATE web_admins SET password='${bcrypt_hash}' WHERE username='admin';" 2>/dev/null
    if [[ $? -eq 0 ]]; then
        # 重启服务使 session 失效
        if systemctl is-active --quiet ocserv-manager; then
            systemctl restart ocserv-manager
            binfo "Management panel restarted" "管理面板已重启"
        fi
        bsuccess "Admin password reset to: netglimmer" "admin 用户密码已重置为: netglimmer"
    else
        berror "Password reset failed" "密码重置失败"
        return 1
    fi
}

restart_manager_if_running() {
    if systemctl is-active --quiet ocserv-manager; then
        binfo "Restarting management panel to sync changes..." "重启管理面板以同步变更..."
        systemctl restart ocserv-manager
        bsuccess "Management panel restarted" "管理面板已重启"
    fi
}

export_config_backup() {
    echo ""
    print_info "=== Export Config Backup / 导出配置备份 ==="
    if ! systemctl is-active --quiet ocserv-manager; then
        print_error "Management panel is not running, start it first: systemctl start ocserv-manager"
        print_error "管理面板服务未运行，请先启动: systemctl start ocserv-manager"
        return 1
    fi
    local token_file="/etc/ocserv-panel/internal_token"
    local port_file="/etc/ocserv-panel/web_port"
    if [[ ! -f "$token_file" ]]; then
        print_error "内部令牌文件不存在: $token_file"
        return 1
    fi
    local token
    token=$(cat "$token_file")
    local port="8088"
    [[ -f "$port_file" ]] && port=$(cat "$port_file")

    # 启用备份加密时导出的是密文（与 web 手动导出策略一致，绝不回退明文）
    local suffix="zip"
    if [[ "$(sqlite3 "$DB_PATH" "SELECT value FROM system_settings WHERE key='backup_encrypt_enabled';" 2>/dev/null)" == "true" ]]; then
        suffix="zip.enc"
    fi
    local out="/root/netglimmer-config-backup-$(date +%Y%m%d-%H%M%S).${suffix}"

    print_info "Exporting config backup (same logic as web manual export)..." "正在导出配置备份（与 web 页面手动导出同逻辑）..."
    if curl -fsS -H "X-Internal-Token: ${token}" "http://127.0.0.1:${port}/api/internal/backup-download" -o "$out" && [[ -s "$out" ]]; then
        chmod 600 "$out"
        print_success "Config backup exported: $out"
        print_success "配置备份已导出: $out（备份含敏感信息，请妥善保管）"
    else
        print_error "Export failed, check panel logs: journalctl -u ocserv-manager -n 50"
        print_error "导出失败，查看面板日志: journalctl -u ocserv-manager -n 50"
        rm -f "$out"
        return 1
    fi
}

main_menu() {
    # 交互菜单内关闭 errexit：菜单中大量命令（如 systemctl status 在服务停止时、
    # grep 无匹配时）会返回非零，若保留 set -e 会导致整个脚本意外退出。
    # 直连 install/uninstall 入口不走此函数，仍保留 set -e 快速失败。
    set +e
    while true; do
        echo ""
        print_info "=========================================="
        print_info "  Netglimmer VPN Manager  / 一键管理脚本"
        print_info "=========================================="
        echo "1. Install           / 安装 Netglimmer VPN"
        echo "2. Uninstall         / 卸载 Netglimmer VPN"
        echo "3. User Management   / 用户管理"
        echo "4. Group Management  / 用户组管理"
        echo "5. Resource Mgmt     / 资源管理"
        echo "6. Service Mgmt      / 服务管理"
        echo "7. Ban Management    / 封禁管理"
        echo "8. Rebuild Panel     / 重新编译面板"
        echo "9. Reset Admin Pass   / 重置管理员密码"
        echo "10. Export Backup    / 导出配置备份"
        echo "0. Exit              / 退出"
        echo ""
        read -p "Select [0-10]: " choice
        case $choice in
            1) install_ocserv ;;
            2) uninstall_ocserv ;;
            3) user_management ;;
            4) group_management ;;
            5) resource_management ;;
            6) service_management ;;
            7) ban_management ;;
            8)
                check_root
                build_manager
                systemctl restart ocserv-manager
                print_success "Panel updated & restarted / 管理面板已更新并重启"
                ;;
            9) reset_admin_password ;;
            10) export_config_backup ;;
            0) exit 0 ;;
            *) print_error "Invalid selection / 无效的选择" ;;
        esac
    done
}

choose_language
check_root
if [[ "$1" == "console" ]]; then
    # 明细模式: ./xxx.sh console install|uninstall
    verify_console_password
    case "${2:-}" in
        install)   install_ocserv ;;
        uninstall) uninstall_ocserv ;;
        *)         berror "Usage: $0 console install|uninstall" "用法: $0 console install|uninstall"; exit 1 ;;
    esac
elif [[ "$1" == "install" ]]; then
    # 默认进度条模式
    install_ocserv
elif [[ "$1" == "uninstall" ]]; then
    uninstall_ocserv
elif [[ "$1" == "manage" ]]; then
    main_menu
else
    main_menu
fi