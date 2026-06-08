#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
# lib/bootstrap.sh — host prerequisites for a fresh Ubuntu/Debian/RHEL box.
#
# Source from mobius_install.sh (or any per-project install.sh that
# wants to leverage it directly):    . "${LIB_DIR}/bootstrap.sh"
#
# Exports:
#   - mobius_bootstrap__missing <cmd ...>              prints missing names
#   - mobius_bootstrap__ensure_deps                    apt/dnf install docker+git+curl+compose-v2
#   - mobius_bootstrap__ensure_docker_running          start daemon + add user to docker group
#   - mobius_bootstrap__sg_reexec <script> "$@"        re-exec under `sg docker` (after group add)
#   - mobius_bootstrap__run                            all of the above, in order, idempotent
#
# Extracted from the canonical TILES install.sh §"DEPENDENCIES" (commits 6adfc7d
# `self-re-exec under sg docker` + 4080459 `install docker compose v2 plugin` +
# c9a64f3 `ensure deps instead of only instructing`).
#
# Designed for curl|bash: requires `bash`, `command`, `sudo`. No yq/jq, no python.
# Safe under set -u.
# ─────────────────────────────────────────────────────────────────────

[[ -n "${_MOBIUS_BOOTSTRAP_SOURCED:-}" ]] && return 0 2>/dev/null
_MOBIUS_BOOTSTRAP_SOURCED=1

# Pull in log helpers if available; otherwise inline minimal stubs.
if [[ -n "${LIB_DIR:-}" && -f "${LIB_DIR}/log.sh" ]]; then
    # shellcheck disable=SC1091
    . "${LIB_DIR}/log.sh"
else
    : "${RED:=$'\033[0;31m'}" "${GREEN:=$'\033[0;32m'}" "${YELLOW:=$'\033[1;33m'}" "${CYAN:=$'\033[0;36m'}" "${BOLD:=$'\033[1m'}" "${NC:=$'\033[0m'}"
    mobius_log__step() { echo -e "${BOLD}→ $*${NC}"; }
    mobius_log__info() { echo -e "${CYAN}$*${NC}"; }
    mobius_log__warn() { echo -e "${YELLOW}⚠ $*${NC}" >&2; }
    mobius_log__err()  { echo -e "${RED}✗ $*${NC}" >&2; }
    mobius_log__ok()   { echo -e "${GREEN}✓ $*${NC}"; }
fi

mobius_bootstrap__missing() {
    # Print missing-command names to stdout, one per line.
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || echo "$cmd"
    done
}

mobius_bootstrap__ensure_deps() {
    # Install missing host tools via apt (Debian-family) or dnf (RHEL-family).
    # docker compose v2 is a SEPARATE package from the engine (probed via
    # `docker compose version`); installed as docker-compose-v2 / docker-compose-plugin.
    local missing
    missing="$(mobius_bootstrap__missing docker git curl)"
    if ! docker compose version >/dev/null 2>&1; then
        missing="${missing} compose-plugin"
    fi
    missing="${missing# }"
    [ -z "$missing" ] && { mobius_log__ok "All host tools present"; return 0; }

    mobius_log__warn "Missing host tools — installing: $(printf '%s ' $missing)"

    if command -v apt-get >/dev/null 2>&1; then
        local pkgs="" m
        for m in $missing; do
            case "$m" in
                docker)         pkgs+=" docker.io" ;;
                compose-plugin) pkgs+=" docker-compose-v2" ;;
                *)              pkgs+=" $m" ;;
            esac
        done
        sudo apt-get update -qq || true
        sudo apt-get install -y $pkgs || { mobius_log__err "apt-get install failed"; return 1; }
    elif command -v dnf >/dev/null 2>&1; then
        local pkgs="" m
        for m in $missing; do
            case "$m" in
                compose-plugin) pkgs+=" docker-compose-plugin" ;;
                *)              pkgs+=" $m" ;;
            esac
        done
        sudo dnf install -y $pkgs || { mobius_log__err "dnf install failed"; return 1; }
    else
        mobius_log__err "No supported package manager (apt-get / dnf) found."
        mobius_log__info "  Please install manually: $missing"
        mobius_log__info "  Docker: https://docs.docker.com/engine/install/"
        return 1
    fi

    mobius_log__ok "Installed: $(printf '%s ' $missing)"
}

mobius_bootstrap__ensure_docker_running() {
    # Probe `docker ps` (cheapest "daemon up + I can talk to it"). Failure path:
    # start daemon → add user to docker group. Caller is responsible for the
    # sg re-exec dance (see mobius_bootstrap__sg_reexec) if group was just added.
    #
    # Returns:
    #   0 = docker reachable (either already or after daemon start)
    #   2 = group was added, caller MUST sg-reexec
    #   1 = unreachable, daemon couldn't start or group-add didn't help
    if docker ps >/dev/null 2>&1; then return 0; fi

    if command -v systemctl >/dev/null 2>&1; then
        mobius_log__info "Starting docker daemon..."
        sudo systemctl enable --now docker >/dev/null 2>&1 || sudo systemctl start docker || true
        sleep 2
        if docker ps >/dev/null 2>&1; then
            mobius_log__ok "Docker daemon is running"
            return 0
        fi
    fi

    if ! id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        mobius_log__warn "Adding $USER to the 'docker' group..."
        sudo usermod -aG docker "$USER" || true
    fi

    if command -v sg >/dev/null 2>&1 && sg docker -c 'docker ps >/dev/null 2>&1'; then
        mobius_log__ok "Docker accessible via sg; caller should re-exec under sg"
        return 2
    fi

    mobius_log__err "Docker installed but unreachable, even after daemon start + group add."
    mobius_log__info "  Inspect: sudo systemctl status docker"
    mobius_log__info "           journalctl -u docker --no-pager -n 50"
    return 1
}

mobius_bootstrap__sg_reexec() {
    # Re-exec the given script under `sg docker -c` so the freshly-added docker
    # group membership is active in the child shell. Group changes never
    # propagate to the parent shell session — sg/newgrp are the only
    # logout-free way to get them in-process.
    #
    # Usage: mobius_bootstrap__sg_reexec "$0" "$@"
    local script="$1"; shift
    local arg args_quoted=""
    for arg in "$@"; do
        args_quoted+="$(printf '%q ' "$arg")"
    done
    mobius_log__step "Re-executing $script in a docker-group shell..."
    exec sg docker -c "exec $(printf '%q' "$script") $args_quoted"
}

mobius_bootstrap__run() {
    # Convenience: do the full bootstrap sequence. Caller passes ("$0" "$@") so
    # the sg re-exec can replay the original invocation.
    #
    # Usage:  mobius_bootstrap__run "$0" "$@"
    mobius_log__step "Pre-flight host bootstrap"
    mobius_bootstrap__ensure_deps || return 1

    mobius_bootstrap__ensure_docker_running
    local rc=$?
    case "$rc" in
        0) return 0 ;;
        2) mobius_bootstrap__sg_reexec "$@" ;;   # never returns
        *) return 1 ;;
    esac
}
