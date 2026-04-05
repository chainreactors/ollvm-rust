# ============================================================================
# ollvm-rust Docker image
#
# Multi-stage build: compile OLLVM pass plugin, then assemble a Rust
# cross-compilation environment with OLLVM support for three targets:
#   - x86_64-unknown-linux-gnu
#   - x86_64-pc-windows-gnu
#   - x86_64-pc-windows-msvc
#
# Build args:
#   LLVM_VERSION  — LLVM major version (17-21, default: 20)
#   RUST_VERSION  — Rust toolchain version (default: auto-selected to match LLVM)
#   XWIN_VERSION  — xwin version for MSVC cross-compile (default: 0.6.5)
#
# Usage:
#   docker build -t ollvm-rust .
#   docker build -t ollvm-rust --build-arg LLVM_VERSION=21 --build-arg RUST_VERSION=1.90.0 .
#
# ============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Build the OLLVM pass plugin
# ---------------------------------------------------------------------------
FROM ubuntu:22.04 AS builder

ARG LLVM_VERSION=20

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake ninja-build git ca-certificates \
        wget gnupg lsb-release libzstd-dev \
    && rm -rf /var/lib/apt/lists/*

# Add LLVM apt repo
RUN wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | \
        gpg --dearmor -o /usr/share/keyrings/llvm-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/llvm-archive-keyring.gpg] \
        http://apt.llvm.org/$(lsb_release -cs)/ \
        llvm-toolchain-$(lsb_release -cs)-${LLVM_VERSION} main" \
        > /etc/apt/sources.list.d/llvm.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends llvm-${LLVM_VERSION}-dev && \
    rm -rf /var/lib/apt/lists/*

COPY ollvm-pass/ /src/ollvm-pass/

RUN cmake -G Ninja \
        -S /src/ollvm-pass \
        -B /build \
        -DCMAKE_CXX_STANDARD=17 \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON \
        -DLT_LLVM_INSTALL_DIR=/usr/lib/llvm-${LLVM_VERSION} && \
    cmake --build /build -j"$(nproc)" && \
    # Verify symbol export
    nm -D /build/obfuscation/libLLVMObfuscationx.so | grep -q llvmGetPassPluginInfo

# ---------------------------------------------------------------------------
# Stage 2: Runtime image with Rust + LLVM tools + OLLVM
# ---------------------------------------------------------------------------
FROM ubuntu:22.04

ARG LLVM_VERSION=20
# LLVM-to-Rust version mapping (pick a known-good version for each LLVM):
#   LLVM 17 → 1.73.0,  LLVM 18 → 1.78.0,  LLVM 19 → 1.84.0
#   LLVM 20 → 1.87.0,  LLVM 21 → 1.90.0
ARG RUST_VERSION=""
ARG XWIN_VERSION=0.6.5

ENV DEBIAN_FRONTEND=noninteractive
ENV LLVM_VERSION=${LLVM_VERSION}

# Resolve Rust version from LLVM version if not specified
SHELL ["/bin/bash", "-c"]

# Install system packages + LLVM runtime tools
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg lsb-release \
        build-essential gcc-mingw-w64-x86-64 \
        libzstd-dev \
    && rm -rf /var/lib/apt/lists/*

# Add LLVM apt repo and install tools (opt, clang, lld)
RUN wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | \
        gpg --dearmor -o /usr/share/keyrings/llvm-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/llvm-archive-keyring.gpg] \
        http://apt.llvm.org/$(lsb_release -cs)/ \
        llvm-toolchain-$(lsb_release -cs)-${LLVM_VERSION} main" \
        > /etc/apt/sources.list.d/llvm.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        llvm-${LLVM_VERSION} \
        clang-${LLVM_VERSION} \
        lld-${LLVM_VERSION} && \
    rm -rf /var/lib/apt/lists/*

# Verify required LLVM tools exist
RUN opt-${LLVM_VERSION} --version && \
    clang-${LLVM_VERSION} --version && \
    lld-link-${LLVM_VERSION} --version

# Copy OLLVM pass plugin from builder
COPY --from=builder /build/obfuscation/libLLVMObfuscationx.so /usr/local/lib/

# Copy linker wrapper
COPY docker/ollvm-rustc-linker.sh /usr/local/bin/ollvm-rustc-linker
RUN chmod +x /usr/local/bin/ollvm-rustc-linker

# Install Rust (auto-select version matching LLVM if not specified)
RUN if [ -z "${RUST_VERSION}" ]; then \
        case "${LLVM_VERSION}" in \
            17) RUST_VER=1.73.0 ;; \
            18) RUST_VER=1.78.0 ;; \
            19) RUST_VER=1.84.0 ;; \
            20) RUST_VER=1.87.0 ;; \
            21) RUST_VER=1.90.0 ;; \
            *)  RUST_VER=1.87.0 ;; \
        esac; \
    else \
        RUST_VER="${RUST_VERSION}"; \
    fi && \
    echo "Installing Rust ${RUST_VER} for LLVM ${LLVM_VERSION}" && \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
        sh -s -- -y --default-toolchain "${RUST_VER}" && \
    . /root/.cargo/env && \
    rustup target add x86_64-pc-windows-gnu x86_64-pc-windows-msvc && \
    # Verify LLVM version matches
    RUST_LLVM=$(rustc --version --verbose | grep "LLVM version" | grep -oP '\d+' | head -1) && \
    echo "Rust LLVM: ${RUST_LLVM}, Target LLVM: ${LLVM_VERSION}" && \
    if [ "${RUST_LLVM}" != "${LLVM_VERSION}" ]; then \
        echo "WARNING: Rust uses LLVM ${RUST_LLVM} but pass is built for LLVM ${LLVM_VERSION}"; \
    fi

ENV PATH="/root/.cargo/bin:${PATH}"

# Install xwin for MSVC cross-compilation
RUN cargo install xwin --version "=${XWIN_VERSION}" --locked && \
    xwin --accept-license splat --output /opt/xwin && \
    rm -rf /root/.cargo/registry /root/.cargo/git /tmp/*

# Set default env
ENV OLLVM_PLUGIN=/usr/local/lib/libLLVMObfuscationx.so
ENV OLLVM_PASSES="irobf(irobf-indbr)"

WORKDIR /src

# ---------------------------------------------------------------------------
# Usage examples (run from host):
#
# Build image:
#   docker build -t ollvm-rust .
#
# Linux target:
#   docker run --rm -v "$(pwd):/src" ollvm-rust bash -c '
#     OLLVM_CRATE=my_crate \
#     RUSTFLAGS="-Clinker-plugin-lto -Clinker=ollvm-rustc-linker \
#       -Clink-arg=-fuse-ld=lld-'${LLVM_VERSION}'" \
#     cargo build --release'
#
# Windows GNU target:
#   docker run --rm -v "$(pwd):/src" ollvm-rust bash -c '
#     OLLVM_CRATE=my_crate \
#     RUSTFLAGS="-Clinker-plugin-lto -Clinker=ollvm-rustc-linker \
#       -Clink-arg=--target=x86_64-w64-windows-gnu \
#       -Clink-arg=-fuse-ld=lld-'${LLVM_VERSION}'" \
#     cargo build --release --target x86_64-pc-windows-gnu'
#
# Windows MSVC target:
#   docker run --rm -v "$(pwd):/src" ollvm-rust bash -c '
#     OLLVM_CRATE=my_crate \
#     RUSTFLAGS="-Clinker-plugin-lto -Clinker=ollvm-rustc-linker \
#       -Clink-arg=/libpath:/opt/xwin/crt/lib/x86_64 \
#       -Clink-arg=/libpath:/opt/xwin/sdk/lib/um/x86_64 \
#       -Clink-arg=/libpath:/opt/xwin/sdk/lib/ucrt/x86_64" \
#     cargo build --release --target x86_64-pc-windows-msvc'
# ---------------------------------------------------------------------------
