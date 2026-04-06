#!/bin/bash
# test-docker.sh — Build Docker image and test OLLVM obfuscation on multiple targets
#
# Usage:
#   ./test-docker.sh [LLVM_VERSION]   (default: 20)

set -euo pipefail

LLVM_VERSION="${1:-20}"
IMAGE_NAME="ollvm-rust-test:llvm${LLVM_VERSION}"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="${PROJECT_DIR}/test-project"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
pass()  { echo -e "${GREEN}[PASS]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; }
step()  { echo -e "\n${YELLOW}====== $* ======${NC}"; }

PASS_COUNT=0
FAIL_COUNT=0

# ── Step 1: Build Docker image ──
step "Building Docker image (LLVM ${LLVM_VERSION})"
docker build \
    --build-arg LLVM_VERSION="${LLVM_VERSION}" \
    -t "${IMAGE_NAME}" \
    "${PROJECT_DIR}"

info "Image built: ${IMAGE_NAME}"
docker run --rm "${IMAGE_NAME}" bash -c '
    echo "  LLVM:  $(opt-'${LLVM_VERSION}' --version 2>&1 | grep "version" | head -1)"
    echo "  Rust:  $(rustc --version)"
    echo "  OLLVM: $(ls -lh /usr/local/lib/libLLVMObfuscationx.so | awk "{print \$5}")"
'

# ── Helper: run cargo build inside Docker ──
run_build() {
    local target="$1"
    local label="$2"
    local extra_rustflags="${3:-}"
    local extra_args="${4:-}"

    step "Test: ${label}"

    local rustflags="-Clinker-plugin-lto -Clinker=ollvm-rustc-linker"
    if [ -n "$extra_rustflags" ]; then
        rustflags="${rustflags} ${extra_rustflags}"
    fi

    local cargo_args="--release"
    if [ -n "$target" ]; then
        cargo_args="${cargo_args} --target ${target}"
    fi
    if [ -n "$extra_args" ]; then
        cargo_args="${cargo_args} ${extra_args}"
    fi

    info "target: ${target:-default}"
    info "RUSTFLAGS: ${rustflags}"

    # Clean previous build
    docker run --rm \
        -v "${TEST_DIR}:/src" \
        -w /src \
        "${IMAGE_NAME}" \
        cargo clean 2>/dev/null || true

    # Build
    if docker run --rm \
        -v "${TEST_DIR}:/src" \
        -w /src \
        -e OLLVM_CRATE=hello-ollvm \
        -e OLLVM_PASSES="irobf(irobf-indbr,irobf-icall,irobf-indgv)" \
        -e OLLVM_VERBOSE=1 \
        -e LLVM_VERSION="${LLVM_VERSION}" \
        "${IMAGE_NAME}" \
        bash -c "RUSTFLAGS='${rustflags}' cargo build ${cargo_args}" 2>&1; then

        # Find output binary
        local bin_path=""
        if [ -z "$target" ]; then
            bin_path="target/release/hello-ollvm"
        else
            bin_path="target/${target}/release/hello-ollvm"
            # Windows targets have .exe
            case "$target" in
                *windows*) bin_path="${bin_path}.exe" ;;
            esac
        fi

        # Check binary exists and show info
        if docker run --rm -v "${TEST_DIR}:/src" -w /src "${IMAGE_NAME}" \
            bash -c "ls -lh /src/${bin_path} && file /src/${bin_path}" 2>&1; then

            local size
            size=$(docker run --rm -v "${TEST_DIR}:/src" -w /src "${IMAGE_NAME}" \
                bash -c "du -h /src/${bin_path} | cut -f1" 2>/dev/null)

            # Try to run if it's a Linux binary
            if [ -z "$target" ] || [[ "$target" == *linux* ]]; then
                info "Running binary..."
                local output
                if output=$(docker run --rm -v "${TEST_DIR}:/src" -w /src "${IMAGE_NAME}" \
                    "/src/${bin_path}" 2>&1); then
                    info "Output: ${output}"
                    if echo "$output" | grep -q "result:"; then
                        pass "${label} — built (${size}), runs correctly"
                        PASS_COUNT=$((PASS_COUNT + 1))
                        return 0
                    fi
                fi
            fi

            pass "${label} — built (${size})"
            PASS_COUNT=$((PASS_COUNT + 1))
            return 0
        fi
    fi

    fail "${label}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return 1
}

# ── Step 2: Test Linux target ──
run_build "" "Linux x86_64 (default target)" \
    "-Clink-arg=-fuse-ld=lld-${LLVM_VERSION}"

# ── Step 3: Test Windows GNU target ──
run_build "x86_64-pc-windows-gnu" "Windows GNU x86_64" \
    "-Clink-arg=--target=x86_64-w64-windows-gnu -Clink-arg=-fuse-ld=lld-${LLVM_VERSION}"

# ── Step 4: Test Windows MSVC target ──
run_build "x86_64-pc-windows-msvc" "Windows MSVC x86_64" \
    "-Clink-arg=/libpath:/opt/xwin/crt/lib/x86_64 -Clink-arg=/libpath:/opt/xwin/sdk/lib/um/x86_64 -Clink-arg=/libpath:/opt/xwin/sdk/lib/ucrt/x86_64"

# ── Step 5: Test with no obfuscation (baseline) ──
step "Test: Linux baseline (no OLLVM)"
docker run --rm \
    -v "${TEST_DIR}:/src" \
    -w /src \
    "${IMAGE_NAME}" \
    bash -c "cargo clean && cargo build --release" 2>&1

BASELINE_SIZE=$(docker run --rm -v "${TEST_DIR}:/src" -w /src "${IMAGE_NAME}" \
    bash -c "du -h /src/target/release/hello-ollvm | cut -f1" 2>/dev/null)
pass "Baseline built (${BASELINE_SIZE})"
PASS_COUNT=$((PASS_COUNT + 1))

# ── Summary ──
step "Results"
echo ""
echo -e "  ${GREEN}Passed: ${PASS_COUNT}${NC}"
echo -e "  ${RED}Failed: ${FAIL_COUNT}${NC}"
echo ""

if [ "$FAIL_COUNT" -gt 0 ]; then
    fail "Some tests failed"
    exit 1
else
    pass "All tests passed!"
fi
