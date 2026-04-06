#!/bin/bash
# ollvm-rustc-linker.sh — Universal OLLVM linker wrapper for Rust
#
# Auto-detects LLVM version from active rustc, selects matching pass plugin
# and LLVM tools. No manual version numbers needed.
#
# Env vars:
#   OLLVM_CRATE    — crate name to obfuscate (required)
#   OLLVM_PASSES   — pass pipeline (default: irobf(irobf-indbr))
#   OLLVM_VERBOSE  — set to 1 for debug output
#   LLVM_VERSION   — override LLVM version (auto-detected from rustc if unset)
#   OLLVM_PLUGIN   — override plugin path (auto-detected if unset)
#   OLLVM_OPT      — override opt binary (auto-detected if unset)

set -eo pipefail

# ── Auto-detect LLVM version from rustc ──
if [ -z "${LLVM_VERSION:-}" ]; then
    LLVM_VERSION=$(rustc --version --verbose 2>/dev/null | grep "LLVM version" | grep -oP '\d+' | head -1 || echo "")
fi
: "${LLVM_VERSION:=20}"

: "${OLLVM_PASSES:=irobf(irobf-indbr)}"
: "${OLLVM_PLUGIN:=/usr/local/lib/ollvm/libLLVMObfuscationx-${LLVM_VERSION}.so}"
: "${OLLVM_OPT:=opt-${LLVM_VERSION}}"
: "${OLLVM_CRATE:=}"
: "${OLLVM_VERBOSE:=0}"

CLANG="clang-${LLVM_VERSION}"
LLD_LINK="lld-link-${LLVM_VERSION}"

log() { [ "$OLLVM_VERBOSE" = "1" ] && echo "[ollvm-linker] $*" >&2 || true; }

# ── Validate plugin exists ──
if [ -n "${OLLVM_CRATE}" ] && [ ! -f "${OLLVM_PLUGIN}" ]; then
    echo "[ollvm-linker] ERROR: plugin not found: ${OLLVM_PLUGIN}" >&2
    echo "[ollvm-linker] Available:" >&2
    ls /usr/local/lib/ollvm/libLLVMObfuscationx-*.so 2>/dev/null | sed 's/^/  /' >&2
    exit 1
fi

log "LLVM ${LLVM_VERSION} | opt: ${OLLVM_OPT} | plugin: $(basename ${OLLVM_PLUGIN})"
log "passes: ${OLLVM_PASSES}"

# ── Step 1: Detect target type ──
IS_MSVC=false
for arg in "$@"; do
    case "$arg" in
        /[Ll][Ii][Bb][Pp][Aa][Tt][Hh]:*|/[Oo][Uu][Tt]:*|/[Nn][Oo][Ll][Oo][Gg][Oo])
            IS_MSVC=true; break ;;
    esac
done

log "target: $([ "$IS_MSVC" = true ] && echo MSVC || echo ELF/GNU)"
log "crate: ${OLLVM_CRATE:-<none>}"

# ── Step 2: Obfuscate matching bitcode ──
if [ -n "${OLLVM_CRATE}" ]; then
    CRATE_PATTERN=$(echo "${OLLVM_CRATE}" | tr '-' '_')

    for arg in "$@"; do
        [ -f "$arg" ] || continue
        case "$arg" in
            *"${CRATE_PATTERN}"*.o)
                log "matched: $(basename "$arg")"
                if "${OLLVM_OPT}" \
                    -load-pass-plugin="${OLLVM_PLUGIN}" \
                    --passes="${OLLVM_PASSES}" \
                    "$arg" -o "${arg}.obf" 2>/dev/null; then
                    mv "${arg}.obf" "$arg"
                    log "obfuscated: $(basename "$arg")"
                else
                    log "WARNING: opt failed on $(basename "$arg"), using original"
                    rm -f "${arg}.obf"
                fi
                ;;
        esac
    done
fi

# ── Step 3: Delegate to real linker ──
if [ "$IS_MSVC" = true ]; then
    log "exec: ${LLD_LINK} $*"
    exec "${LLD_LINK}" "$@"
else
    # Auto-inject -fuse-ld=lld-XX unless user already specified one
    HAS_FUSE_LD=false
    for arg in "$@"; do
        case "$arg" in -fuse-ld=*) HAS_FUSE_LD=true; break ;; esac
    done

    if [ "$HAS_FUSE_LD" = false ]; then
        log "exec: ${CLANG} -fuse-ld=lld-${LLVM_VERSION} $*"
        exec "${CLANG}" -fuse-ld="lld-${LLVM_VERSION}" "$@"
    else
        log "exec: ${CLANG} $*"
        exec "${CLANG}" "$@"
    fi
fi
