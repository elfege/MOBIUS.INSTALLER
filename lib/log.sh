#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
# lib/log.sh — color + log helpers.
#
# Source from any installer script:    . "${LIB_DIR}/log.sh"
#
# Provides:
#   - color vars (idempotent; existing values preserved): RED GREEN YELLOW
#     CYAN BOLD NC
#   - mobius_log__info  / mobius_log__warn / mobius_log__err / mobius_log__ok
#   - mobius_log__step   (prints "→ <msg>" in bold)
#
# Designed for curl|bash: no external dependencies, safe under set -u.
# ─────────────────────────────────────────────────────────────────────

# Idempotent guard.
[[ -n "${_MOBIUS_LOG_SOURCED:-}" ]] && return 0 2>/dev/null
_MOBIUS_LOG_SOURCED=1

: "${RED:=$'\033[0;31m'}"
: "${GREEN:=$'\033[0;32m'}"
: "${YELLOW:=$'\033[1;33m'}"
: "${CYAN:=$'\033[0;36m'}"
: "${BOLD:=$'\033[1m'}"
: "${NC:=$'\033[0m'}"

mobius_log__step() { echo -e "${BOLD}→ $*${NC}"; }
mobius_log__info() { echo -e "${CYAN}$*${NC}"; }
mobius_log__warn() { echo -e "${YELLOW}⚠ $*${NC}" >&2; }
mobius_log__err()  { echo -e "${RED}✗ $*${NC}" >&2; }
mobius_log__ok()   { echo -e "${GREEN}✓ $*${NC}"; }
