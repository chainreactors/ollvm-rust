#!/bin/bash
# ollvm-rustc-linker.sh — Universal OLLVM linker wrapper for Rust
#
# Works as -Clinker for ALL targets (Linux/Windows GNU/Windows MSVC).
# Intercepts bitcode .o files, applies OLLVM pass, then delegates to the
# correct real linker based on invocation style.
#
# Env vars:
#   OLLVM_CRATE    — crate name to obfuscate (required, e.g. "my_app")
#   OLLVM_PASSES   — pass pipeline (default: irobf(irobf-indbr))
#   OLLVM_PLUGIN   — path to .so (default: /usr/local/lib/libLLVMObfuscationx.so)
#   OLLVM_OPT      — opt binary (default: opt-${LLVM_VERSION})
#   OLLVM_CLANG    — clang binary for ELF/GNU (default: clang-${LLVM_VERSION})
#   OLLVM_LLD_LINK — lld-link binary for MSVC (default: lld-link-${LLVM_VERSION})
#   OLLVM_VERBOSE  — set to 1 for debug output
#   LLVM_VERSION   — LLVM major version (default: 20)

set -eo pipefail

: "${LLVM_VERSION:=20}"
: "${OLLVM_PASSES:=irobf(irobf-indbr)}"
: "${OLLVM_PLUGIN:=/usr/local/lib/libLLVMObfuscationx.so}"
: "${OLLVM_OPT:=opt-${LLVM_VERSION}}"
: "${OLLVM_CLANG:=clang-${LLVM_VERSION}}"
: "${OLLVM_LLD_LINK:=lld-link-${LLVM_VERSION}}"
: "${OLLVM_CRATE:=}"
: "${OLLVM_VERBOSE:=0}"

log() { [ "$OLLVM_VERBOSE" = "1" ] && echo "[ollvm-linker] $*" >&2 || true; }

# ── Step 1: Detect target type from arguments ──
IS_MSVC=false
for arg in "$@"; do
    case "$arg" in
        /[Ll][Ii][Bb][Pp][Aa][Tt][Hh]:*|/[Oo][Uu][Tt]:*|/[Nn][Oo][Ll][Oo][Gg][Oo])
            IS_MSVC=true; break ;;
    esac
done

log "target: $([ "$IS_MSVC" = true ] && echo MSVC || echo ELF/GNU)"
log "crate: ${OLLVM_CRATE:-<none>}"
log "passes: ${OLLVM_PASSES}"

# ── Step 2: Find and obfuscate user crate bitcode ──
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
    log "exec: ${OLLVM_LLD_LINK} ..."
    exec "${OLLVM_LLD_LINK}" "$@"
else
    log "exec: ${OLLVM_CLANG} ..."
    exec "${OLLVM_CLANG}" "$@"
fi
