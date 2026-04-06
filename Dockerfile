# ============================================================================
# ollvm-rust Docker image (all-in-one)
#
# Contains OLLVM pass plugins for LLVM 17-21 and matching Rust toolchains.
# The linker wrapper auto-detects the active Rust toolchain's LLVM version
# and uses the correct pass plugin + opt binary.
#
# Supported targets:
#   - x86_64-unknown-linux-gnu
#   - x86_64-pc-windows-gnu
#   - x86_64-pc-windows-msvc
#
# Usage:
#   docker build -t ollvm-rust .
#
#   # Use any installed Rust version:
#   docker run --rm -v "$(pwd):/src" ollvm-rust bash -c '
#     rustup default nightly-2025-03-15 &&
#     OLLVM_CRATE=my_crate cargo build --release'
#
# ============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Build OLLVM pass plugin for ALL LLVM versions
# ---------------------------------------------------------------------------
FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake ninja-build ca-certificates \
        wget gnupg lsb-release libzstd-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Add LLVM apt repo (all versions share the same GPG key)
RUN wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | \
        gpg --dearmor -o /usr/share/keyrings/llvm-archive-keyring.gpg && \
    for v in 17 18 19 20 21; do \
        echo "deb [signed-by=/usr/share/keyrings/llvm-archive-keyring.gpg] \
            http://apt.llvm.org/$(lsb_release -cs)/ \
            llvm-toolchain-$(lsb_release -cs)-${v} main"; \
    done > /etc/apt/sources.list.d/llvm.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        llvm-17-dev llvm-18-dev llvm-19-dev llvm-20-dev llvm-21-dev && \
    rm -rf /var/lib/apt/lists/*

COPY ollvm-pass/ /src/ollvm-pass/

# Build .so for each LLVM version
RUN for v in 17 18 19 20 21; do \
        echo "=== Building for LLVM ${v} ===" && \
        cmake -G Ninja \
            -S /src/ollvm-pass \
            -B /build-${v} \
            -DCMAKE_CXX_STANDARD=17 \
            -DCMAKE_BUILD_TYPE=Release \
            -DBUILD_SHARED_LIBS=ON \
            -DLT_LLVM_INSTALL_DIR=/usr/lib/llvm-${v} && \
        cmake --build /build-${v} -j"$(nproc)" && \
        nm -D /build-${v}/obfuscation/libLLVMObfuscationx.so | grep -q llvmGetPassPluginInfo && \
        mkdir -p /out && \
        cp /build-${v}/obfuscation/libLLVMObfuscationx.so /out/libLLVMObfuscationx-${v}.so; \
    done

# ---------------------------------------------------------------------------
# Stage 2: Runtime image
# ---------------------------------------------------------------------------
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-c"]

# System packages
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg lsb-release \
        build-essential gcc-mingw-w64-x86-64 gcc-mingw-w64-i686 \
        libzstd-dev protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

# LLVM tools for all versions (opt, clang, lld)
RUN wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | \
        gpg --dearmor -o /usr/share/keyrings/llvm-archive-keyring.gpg && \
    for v in 17 18 19 20 21; do \
        echo "deb [signed-by=/usr/share/keyrings/llvm-archive-keyring.gpg] \
            http://apt.llvm.org/$(lsb_release -cs)/ \
            llvm-toolchain-$(lsb_release -cs)-${v} main"; \
    done > /etc/apt/sources.list.d/llvm.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        llvm-17 clang-17 lld-17 \
        llvm-18 clang-18 lld-18 \
        llvm-19 clang-19 lld-19 \
        llvm-20 clang-20 lld-20 \
        llvm-21 clang-21 lld-21 && \
    rm -rf /var/lib/apt/lists/*

# Copy all OLLVM pass plugins
COPY --from=builder /out/ /usr/local/lib/ollvm/

# Copy linker wrapper
COPY docker/ollvm-rustc-linker.sh /usr/local/bin/ollvm-rustc-linker
RUN chmod +x /usr/local/bin/ollvm-rustc-linker

# Install Rust toolchains (one nightly per LLVM version)
#   LLVM 17 → nightly-2023-09-18  (rustc 1.74.0)
#   LLVM 18 → nightly-2024-03-15  (rustc 1.78.0)
#   LLVM 19 → nightly-2024-09-15  (rustc 1.83.0)
#   LLVM 20 → nightly-2025-03-15  (rustc 1.87.0)
#   LLVM 21 → nightly-2025-08-15  (rustc 1.91.0)
ARG DEFAULT_LLVM=20
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
        sh -s -- -y --default-toolchain none && \
    . /root/.cargo/env && \
    for nightly in \
        nightly-2023-09-18 \
        nightly-2024-03-15 \
        nightly-2024-09-15 \
        nightly-2025-03-15 \
        nightly-2025-08-15; \
    do \
        echo "=== Installing ${nightly} ===" && \
        rustup toolchain install ${nightly} --profile minimal && \
        rustup target add --toolchain ${nightly} \
            x86_64-pc-windows-gnu x86_64-pc-windows-msvc \
            i686-pc-windows-gnu i686-pc-windows-msvc; \
    done && \
    rustup default nightly-2025-03-15 && \
    echo "Installed toolchains:" && rustup toolchain list

ENV PATH="/root/.cargo/bin:${PATH}"

# Install xwin for MSVC cross-compilation
ARG XWIN_VERSION=0.6.5
RUN cargo install xwin --version "=${XWIN_VERSION}" --locked && \
    xwin --accept-license splat --output /opt/xwin && \
    rm -rf /root/.cargo/registry /root/.cargo/git /tmp/*

# Default env
ENV OLLVM_PASSES="irobf(irobf-indbr)"

WORKDIR /src

# ---------------------------------------------------------------------------
# Usage:
#
# Build image:
#   docker build -t ollvm-rust .
#
# ── Linux (default: LLVM 20 / Rust 1.87) ──
#   docker run --rm -v "$(pwd):/src" ollvm-rust bash -c '
#     OLLVM_CRATE=my_crate \
#     OLLVM_PASSES="irobf(irobf-indbr,irobf-icall,irobf-indgv)" \
#     RUSTFLAGS="-Clinker-plugin-lto -Clinker=ollvm-rustc-linker" \
#     cargo build --release'
#
# ── Switch Rust/LLVM version (everything auto-adapts) ──
#   docker run --rm -v "$(pwd):/src" ollvm-rust bash -c '
#     rustup default nightly-2024-09-15 &&
#     OLLVM_CRATE=my_crate \
#     RUSTFLAGS="-Clinker-plugin-lto -Clinker=ollvm-rustc-linker" \
#     cargo build --release'
#
# ── Windows GNU ──
#   docker run --rm -v "$(pwd):/src" ollvm-rust bash -c '
#     OLLVM_CRATE=my_crate \
#     RUSTFLAGS="-Clinker-plugin-lto -Clinker=ollvm-rustc-linker \
#       -Clink-arg=--target=x86_64-w64-windows-gnu" \
#     cargo build --release --target x86_64-pc-windows-gnu'
#
# ── Windows MSVC ──
#   docker run --rm -v "$(pwd):/src" ollvm-rust bash -c '
#     OLLVM_CRATE=my_crate \
#     RUSTFLAGS="-Clinker-plugin-lto -Clinker=ollvm-rustc-linker \
#       -Clink-arg=/libpath:/opt/xwin/crt/lib/x86_64 \
#       -Clink-arg=/libpath:/opt/xwin/sdk/lib/um/x86_64 \
#       -Clink-arg=/libpath:/opt/xwin/sdk/lib/ucrt/x86_64" \
#     cargo build --release --target x86_64-pc-windows-msvc'
#
# Available nightly toolchains:
#   nightly-2023-09-18  →  LLVM 17  (Rust 1.74)
#   nightly-2024-03-15  →  LLVM 18  (Rust 1.78)
#   nightly-2024-09-15  →  LLVM 19  (Rust 1.83)
#   nightly-2025-03-15  →  LLVM 20  (Rust 1.87)  ← default
#   nightly-2025-08-15  →  LLVM 21  (Rust 1.91)
#
# Env vars:
#   OLLVM_CRATE   — crate name to obfuscate (required)
#   OLLVM_PASSES  — pass pipeline (default: irobf(irobf-indbr))
#   OLLVM_VERBOSE — set to 1 for debug output
# ---------------------------------------------------------------------------
