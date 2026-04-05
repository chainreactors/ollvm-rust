#!/bin/bash
#
# ollvm-rust Linux 环境安装脚本
# 支持 Ubuntu 20.04 / 22.04 / 24.04，安装编译依赖并构建 pass plugin
#
# 用法:
#   ./scripts/setup-linux.sh [LLVM_VERSION]
#
# 示例:
#   ./scripts/setup-linux.sh        # 自动检测 rustc nightly 的 LLVM 版本
#   ./scripts/setup-linux.sh 20     # 指定 LLVM 20
#   ./scripts/setup-linux.sh 18     # 指定 LLVM 18
#
# 支持的 LLVM 版本: 17, 18, 19, 20, 21
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ---------------------------------------------------------------------------
# 检测系统
# ---------------------------------------------------------------------------

if [ ! -f /etc/os-release ]; then
    error "仅支持 Ubuntu/Debian 系统"
    exit 1
fi

. /etc/os-release

if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
    error "仅支持 Ubuntu/Debian，当前系统: $ID"
    exit 1
fi

CODENAME="${VERSION_CODENAME:-}"
if [ -z "$CODENAME" ]; then
    error "无法检测系统版本代号"
    exit 1
fi

info "系统: $PRETTY_NAME ($CODENAME)"

# ---------------------------------------------------------------------------
# 确定 LLVM 版本
# ---------------------------------------------------------------------------

detect_rust_llvm_version() {
    if command -v rustc &>/dev/null && rustc +nightly --version &>/dev/null; then
        local llvm_ver
        llvm_ver=$(rustc +nightly --version --verbose 2>/dev/null | grep "LLVM version" | grep -oP '\d+' | head -1)
        if [ -n "$llvm_ver" ]; then
            echo "$llvm_ver"
            return 0
        fi
    fi
    return 1
}

LLVM_VERSION="${1:-}"

if [ -z "$LLVM_VERSION" ]; then
    info "未指定 LLVM 版本，尝试从 rustc nightly 检测..."
    if LLVM_VERSION=$(detect_rust_llvm_version); then
        info "检测到 rustc nightly 使用 LLVM $LLVM_VERSION"
    else
        LLVM_VERSION=20
        warn "未检测到 rustc nightly，使用默认 LLVM $LLVM_VERSION"
    fi
fi

if [[ ! "$LLVM_VERSION" =~ ^(17|18|19|20|21)$ ]]; then
    error "不支持的 LLVM 版本: $LLVM_VERSION (支持: 17, 18, 19, 20, 21)"
    exit 1
fi

info "目标 LLVM 版本: $LLVM_VERSION"

# ---------------------------------------------------------------------------
# 安装基础依赖
# ---------------------------------------------------------------------------

info "安装基础编译依赖..."
sudo apt-get update -y
sudo apt-get install -y \
    build-essential \
    cmake \
    ninja-build \
    git \
    wget \
    lsb-release \
    gnupg \
    software-properties-common \
    libzstd-dev

# ---------------------------------------------------------------------------
# 检查 cmake 版本 (需要 >= 3.20)
# ---------------------------------------------------------------------------

CMAKE_VER=$(cmake --version | head -1 | grep -oP '[\d.]+')
CMAKE_MAJOR=$(echo "$CMAKE_VER" | cut -d. -f1)
CMAKE_MINOR=$(echo "$CMAKE_VER" | cut -d. -f2)

if [ "$CMAKE_MAJOR" -lt 3 ] || { [ "$CMAKE_MAJOR" -eq 3 ] && [ "$CMAKE_MINOR" -lt 20 ]; }; then
    warn "cmake $CMAKE_VER 版本过低 (需要 >= 3.20)，通过 pip 安装新版..."
    sudo apt-get install -y python3-pip
    pip3 install cmake --upgrade
    # pip 安装的 cmake 可能在 ~/.local/bin
    export PATH="$HOME/.local/bin:$PATH"
    CMAKE_VER=$(cmake --version | head -1 | grep -oP '[\d.]+')
    info "cmake 已升级到 $CMAKE_VER"
fi

# ---------------------------------------------------------------------------
# 添加 LLVM apt 源并安装
# ---------------------------------------------------------------------------

LLVM_INSTALL_DIR="/usr/lib/llvm-${LLVM_VERSION}"

if [ -d "$LLVM_INSTALL_DIR" ] && [ -f "$LLVM_INSTALL_DIR/lib/cmake/llvm/LLVMConfig.cmake" ]; then
    info "llvm-${LLVM_VERSION}-dev 已安装，跳过"
else
    info "添加 LLVM ${LLVM_VERSION} apt 源..."

    # 添加 GPG key
    wget -qO /tmp/llvm-snapshot.gpg.key https://apt.llvm.org/llvm-snapshot.gpg.key
    sudo apt-key add /tmp/llvm-snapshot.gpg.key 2>/dev/null || \
        sudo gpg --dearmor -o /usr/share/keyrings/llvm.gpg /tmp/llvm-snapshot.gpg.key 2>/dev/null
    rm -f /tmp/llvm-snapshot.gpg.key

    # 添加源
    LLVM_LIST="/etc/apt/sources.list.d/llvm-${LLVM_VERSION}.list"
    echo "deb http://apt.llvm.org/${CODENAME}/ llvm-toolchain-${CODENAME}-${LLVM_VERSION} main" | \
        sudo tee "$LLVM_LIST" > /dev/null

    info "安装 llvm-${LLVM_VERSION}-dev (可能需要几分钟)..."
    sudo apt-get update -y
    sudo apt-get install -y "llvm-${LLVM_VERSION}-dev"
fi

# 验证安装
if [ ! -f "$LLVM_INSTALL_DIR/lib/cmake/llvm/LLVMConfig.cmake" ]; then
    error "llvm-${LLVM_VERSION}-dev 安装失败: 找不到 LLVMConfig.cmake"
    exit 1
fi

LLVM_FULL_VER=$("$LLVM_INSTALL_DIR/bin/llvm-config" --version 2>/dev/null || echo "unknown")
info "LLVM $LLVM_FULL_VER 安装完成 ($LLVM_INSTALL_DIR)"

# ---------------------------------------------------------------------------
# 编译 pass plugin
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"

info "开始编译 (LLVM $LLVM_VERSION)..."
rm -rf "$BUILD_DIR"

cmake -G "Ninja" \
    -S "$PROJECT_DIR/ollvm-pass" \
    -B "$BUILD_DIR" \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DLT_LLVM_INSTALL_DIR="$LLVM_INSTALL_DIR"

cmake --build "$BUILD_DIR" -j"$(nproc)"

# ---------------------------------------------------------------------------
# 验证产物
# ---------------------------------------------------------------------------

SO_PATH="$BUILD_DIR/obfuscation/libLLVMObfuscationx.so"

if [ ! -f "$SO_PATH" ]; then
    error "编译失败: $SO_PATH 不存在"
    exit 1
fi

# 检查符号导出
if nm -D "$SO_PATH" 2>/dev/null | grep -q llvmGetPassPluginInfo; then
    info "编译成功!"
    echo ""
    echo "  产物: $SO_PATH"
    echo "  大小: $(du -h "$SO_PATH" | cut -f1)"
    echo "  LLVM: $LLVM_FULL_VER"
    echo ""
    echo "  使用方法 (Rust):"
    echo "    cargo +nightly rustc --release -- \\"
    echo "      -Zllvm-plugins=\"$SO_PATH\" \\"
    echo "      -Cpasses=\"irobf(irobf-indbr,irobf-icall,irobf-indgv,irobf-cff,irobf-cse)\""
    echo ""
    echo "  使用方法 (opt):"
    echo "    opt -load-pass-plugin=\"$SO_PATH\" \\"
    echo "      --passes=\"irobf(irobf-indbr,irobf-icall,irobf-indgv,irobf-cff,irobf-cse)\" \\"
    echo "      input.bc -o output.bc"
    echo ""
else
    error "编译产物缺少 llvmGetPassPluginInfo 符号"
    exit 1
fi
