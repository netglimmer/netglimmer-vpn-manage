#!/bin/bash

#################################################################
# Netglimmer VPN 离线 deb 包收集脚本
#
# 用途：在【联网】且与目标机器同发行版/同架构的 Debian/Ubuntu 上运行，
#       将安装脚本所需的全部系统依赖（含传递依赖）下载为 .deb 文件，
#       输出到本目录 offline-debs/，随安装包分发到离线内网机器。
#
# 用法：sudo bash pack_offline_debs.sh
# 要求：root 权限、可用的 apt 网络源、目标机器与本机发行版大版本一致
#
# 说明：
#  - 离线端 netglimmer_vpn_install.sh 检测到 offline-debs/*.deb 后自动
#    进入完全离线安装模式（不改 apt 源、不联网），也可显式加 --offline。
#  - deb 与发行版版本强相关：目标是 Debian 12 就在 Debian 12 上打包，
#    目标是 Ubuntu 22.04 就在 Ubuntu 22.04 上打包，架构也须一致(amd64/arm64)。
#################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/offline-debs"

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] 请以 root 运行: sudo bash $0"
    exit 1
fi

# 与 netglimmer_vpn_install.sh install_dependencies 中的包清单保持一致
# （ocserv 源码编译依赖 + 面板运行依赖 + nginx/openssl/gcc 等后续步骤依赖）
PKGS=(
    # ocserv 编译与运行依赖
    gnutls-bin iptables net-tools iproute2 openssl ca-certificates
    jq ipset iptables-persistent lsb-release curl git sqlite3
    build-essential pkg-config gperf xz-utils meson ninja-build
    libgnutls28-dev nettle-dev libtasn1-6-dev libtasn1-bin
    libev-dev libprotobuf-c-dev protobuf-c-compiler
    libseccomp-dev libreadline-dev liblz4-dev libnl-route-3-dev libtalloc-dev libpam0g-dev
    # 域名动态放行（可选但建议）
    dnsmasq
    # 面板 HTTPS 与 CGO 编译依赖
    nginx gcc
)

echo "==> 发行版: $(. /etc/os-release && echo "$PRETTY_NAME") / 架构: $(dpkg --print-architecture)"
echo "==> 目标输出目录: $OUT_DIR"
echo ""

apt-get update

mkdir -p "$OUT_DIR"

# 收集完整传递依赖闭包：apt-rdepends 优先，缺失时用 apt-cache depends 递归兜底
collect_closure() {
    if command -v apt-rdepends >/dev/null 2>&1; then
        apt-rdepends "${PKGS[@]}" 2>/dev/null | grep -vE '^\s|Depends:|PreDepends:' | sort -u
        return 0
    fi
    local -A seen=()
    local queue=("${PKGS[@]}")
    local pkg
    while [[ ${#queue[@]} -gt 0 ]]; do
        pkg="${queue[0]}"
        queue=("${queue[@]:1}")
        [[ -n "${seen[$pkg]:-}" ]] && continue
        seen[$pkg]=1
        echo "$pkg"
        while IFS= read -r dep; do
            dep="${dep%% *}"          # 去掉版本约束
            dep="${dep##*:any}"       # 去掉 :any 架构后缀
            [[ "$dep" == *:* ]] && dep="${dep%%:*}"   # 去掉其它架构限定
            [[ -z "${seen[$dep]:-}" ]] && queue+=("$dep")
        done < <(apt-cache depends --no-recommends --no-suggests --no-conflicts \
                 --no-breaks --no-replaces --no-enhances "$pkg" 2>/dev/null \
                 | awk '$1 ~ /^(Pre-)?Depends:$/ {print $2}' | sort -u)
    done | sort -u
}

echo "==> 解析依赖闭包（含传递依赖）..."
CLOSURE="$(collect_closure)"
TOTAL=$(echo "$CLOSURE" | wc -l)
echo "==> 共 ${TOTAL} 个候选包，开始下载..."

cd "$OUT_DIR"
ok=0; skip=0; fail_list=()
i=0
while IFS= read -r pkg; do
    i=$((i + 1))
    # 虚拟包/未知包直接跳过
    apt-cache show "$pkg" >/dev/null 2>&1 || { skip=$((skip + 1)); continue; }
    if apt-get download "$pkg" >/dev/null 2>&1; then
        ok=$((ok + 1))
    else
        fail_list+=("$pkg")
    fi
    printf "\r    [%d/%d] 已下载 %d ..." "$i" "$TOTAL" "$ok"
done <<< "$CLOSURE"
echo ""

# 校验：请求的核心包都必须已落地
missing=0
for p in "${PKGS[@]}"; do
    if ! ls "${p}"_*.deb >/dev/null 2>&1 && ! ls "${p}:"*.deb >/dev/null 2>&1; then
        echo "[WARN] 核心包未下载成功: $p"
        missing=1
    fi
done

# 校验：用 dpkg-scanpackages 将离线包生成临时本地源，再以“仅该源”模拟安装，
# 若求解失败说明闭包缺包（本机已装的包会被视为已满足，故仅能检出缺口、不能证明全集）
verify_closure() {
    command -v dpkg-scanpackages >/dev/null 2>&1 || { echo "    (dpkg-scanpackages 不可用，跳过求解校验)"; return 0; }
    local repo_dir lists_dir
    repo_dir="$(mktemp -d)"
    lists_dir="$(mktemp -d)"
    cp "$OUT_DIR"/*.deb "$repo_dir/" 2>/dev/null
    ( cd "$repo_dir" && dpkg-scanpackages . /dev/null 2>/dev/null | gzip -9c > Packages.gz )
    local list_file="$repo_dir/offline.list"
    echo "deb [trusted=yes] file://$repo_dir ./" > "$list_file"
    # 临时源需先 update 建立索引缓存（Lists 隔离到临时目录，不污染系统 apt 状态）
    apt-get update -o Dir::Etc::SourceList="$list_file" \
        -o Dir::Etc::SourceParts=/dev/null \
        -o Dir::State::Lists="$lists_dir" >/dev/null 2>&1
    if apt-get install --simulate --no-download \
         -o Dir::Etc::SourceList="$list_file" \
         -o Dir::Etc::SourceParts=/dev/null \
         -o Dir::State::Lists="$lists_dir" \
         "${PKGS[@]}" >/dev/null 2>&1; then
        rm -rf "$repo_dir" "$lists_dir"
        return 0
    fi
    rm -rf "$repo_dir" "$lists_dir"
    return 1
}

echo "==> 校验离线包闭包自洽性（仅本地源模拟求解，不实际安装）..."
if verify_closure; then
    echo "==> 依赖求解校验通过（本机已装包视为满足，缺口包必被检出）"
else
    echo "[WARN] 依赖求解未通过：闭包可能缺包，请到干净系统复核后再分发"
fi

echo ""
echo "==> 下载完成: 成功 ${ok} / 跳过 ${skip} / 失败 ${#fail_list[@]}"
[[ ${#fail_list[@]} -gt 0 ]] && echo "    失败列表: ${fail_list[*]}"
echo "==> 离线包体积: $(du -sh "$OUT_DIR" | cut -f1)，文件数: $(ls "$OUT_DIR"/*.deb 2>/dev/null | wc -l)"

# 写入发行版标记：安装端据此校验离线包与目标机发行版/架构是否匹配，
# 防止 Debian 12 的 deb 被误装到 Debian 13（或不同架构）机器上
(
    . /etc/os-release
    {
        echo "DISTRO_ID=$ID"
        echo "VERSION_ID=$VERSION_ID"
        echo "CODENAME=$VERSION_CODENAME"
        echo "ARCH=$(dpkg --print-architecture)"
        echo "PKG_COUNT=$(ls "$OUT_DIR"/*.deb 2>/dev/null | wc -l)"
        echo "PACKED_AT=$(date '+%F %T')"
    } > "$OUT_DIR/PACK_INFO"
)
echo "==> 已写入发行版标记: $OUT_DIR/PACK_INFO（$(tr '\n' ' ' < "$OUT_DIR/PACK_INFO" 2>/dev/null | head -c 200)）"

if [[ "$missing" -eq 1 ]]; then
    echo "[ERROR] 存在核心包缺失，离线安装将不完整，请检查上方 WARN 后重试"
    exit 1
fi

echo ""
echo "[SUCCESS] offline-debs/ 已就绪，可随安装包整体拷贝到离线内网机器。"
echo "          安装端执行: bash netglimmer_vpn_install.sh   （安装时对话选择安装方式，检测到离线包时默认推荐离线安装；也可 --offline 强制离线）"
