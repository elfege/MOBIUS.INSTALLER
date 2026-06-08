#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════════════════════╗
# ║  mobius_install.sh                                                                   ║
# ║                                                                                      ║
# ║  Central installer for the MOBIUS suite. Installs all-or-part of MOBIUS on a single  ║
# ║  host, resolving inter-component dependencies, prompting once for AWS-vs-.env mode,  ║
# ║  then orchestrating each component's existing deploy.sh chain.                       ║
# ║                                                                                      ║
# ║      ┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐              ║
# ║      │ host bootstrap   │──▶│ load manifests   │──▶│ resolve deps     │              ║
# ║      │ (apt+docker+sg)  │   │ components/*.yml │   │ + dry-run        │              ║
# ║      └──────────────────┘   └──────────────────┘   └────────┬─────────┘              ║
# ║                                                             ▼                        ║
# ║                                              ┌──────────────────────────┐            ║
# ║                                              │ per-component:           │            ║
# ║                                              │ clone → seed .env →      │            ║
# ║                                              │ exec deploy.sh → health  │            ║
# ║                                              └──────────────────────────┘            ║
# ║                                                                                      ║
# ║  FLAGS:                                                                              ║
# ║    --all                           Install every component (deps resolve)            ║
# ║    --component=<ID>[,<ID>...]     Install specific component(s) + transitive deps    ║
# ║    --list                          Print component IDs + deps and exit               ║
# ║    --dry-run                       Plan + print, do not change state                 ║
# ║    --yes                           Skip the post-dry-run confirm prompt              ║
# ║    --help, -h                      Show usage                                        ║
# ║                                                                                      ║
# ║  ENV OVERRIDES:                                                                      ║
# ║    MOBIUS_INSTALLER_REF            Pin the installer ref (default: latest v*.*.*)    ║
# ║                                                                                      ║
# ║  STATUS: v0.1.0 SCAFFOLD — flag parsing + help work; the host-bootstrap,             ║
# ║  manifest-read, dependency-resolution, and per-component install flows land in       ║
# ║  Phase B / C / D of the v1 plan.                                                     ║
# ╚══════════════════════════════════════════════════════════════════════════════════════╝

[[ -t 1 ]] && clear

set -u

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_R_PATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="${SCRIPT_R_PATH%${SCRIPT_NAME}}"
REPO_ROOT="$(builtin cd "${SCRIPT_DIR}" && pwd)"

# Inline colour fallbacks — under `curl | bash` no sibling helpers exist yet.
: "${RED:=$'\033[0;31m'}"
: "${GREEN:=$'\033[0;32m'}"
: "${YELLOW:=$'\033[1;33m'}"
: "${CYAN:=$'\033[0;36m'}"
: "${BOLD:=$'\033[1m'}"
: "${NC:=$'\033[0m'}"

########################################################################
MOBIUS_INSTALL__ARGS=("$@")
MOBIUS_INSTALL__MODE="menu"        # menu | all | component | list
MOBIUS_INSTALL__COMPONENTS=()
MOBIUS_INSTALL__DRY_RUN=false
MOBIUS_INSTALL__YES=false
########################################################################

safe_exit() {
    local exit_code=${1:-$?}
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
        exit "$exit_code"
    else
        return "$exit_code"
    fi
}

mobius_install__show_help() {
    cat <<EOF

${BOLD}${CYAN}Usage:${NC} $0 [--all | --component=<ID>[,<ID>...]] [--dry-run] [--yes] [--help|-h]

  Install all-or-part of the MOBIUS suite on this host.

${BOLD}Flags:${NC}
  ${CYAN}--all${NC}                            Install every component (transitive deps resolve)
  ${CYAN}--component=<ID>[,<ID>...]${NC}      Install specific component(s). Comma-separated.
                                   Available IDs: TILES, NVR, SMART_HOME (v1)
  ${CYAN}--list${NC}                           Print component IDs + their dependency edges
  ${CYAN}--dry-run${NC}                        Resolve deps + print the install plan only
  ${CYAN}--yes${NC}                            Skip the post-dry-run confirmation prompt
  ${CYAN}--help${NC}, ${CYAN}-h${NC}                       Show this message

${BOLD}Environment overrides:${NC}
  ${CYAN}MOBIUS_INSTALLER_REF${NC}             Pin installer to a git ref
                                   (default: latest v*.*.* tag)

${BOLD}Examples:${NC}
  ${GREEN}$0 --all --yes${NC}                              Install everything, non-interactive
  ${GREEN}$0 --component=NVR --dry-run${NC}                Show the NVR install plan, no changes
  ${GREEN}$0 --component=TILES,SMART_HOME${NC}             Install TILES + SMART_HOME (interactive)
  ${GREEN}$0 --list${NC}                                   List available components

${BOLD}One-liner from the public repo:${NC}
  ${GREEN}curl -fsSL https://raw.githubusercontent.com/elfege/MOBIUS.INSTALLER/main/mobius_install.sh \\
    | bash -s -- --all${NC}

EOF
    safe_exit 0
}

mobius_install__parse_args() {
    local a
    for a in "${MOBIUS_INSTALL__ARGS[@]}"; do
        case "$a" in
            --all)
                MOBIUS_INSTALL__MODE="all"
                ;;
            --component=*)
                MOBIUS_INSTALL__MODE="component"
                IFS=',' read -r -a MOBIUS_INSTALL__COMPONENTS <<< "${a#--component=}"
                ;;
            --list)
                MOBIUS_INSTALL__MODE="list"
                ;;
            --dry-run)
                MOBIUS_INSTALL__DRY_RUN=true
                ;;
            --yes|-y)
                MOBIUS_INSTALL__YES=true
                ;;
            --help|-h)
                mobius_install__show_help
                ;;
            *)
                echo -e "${RED}✗ unknown flag: $a${NC}" >&2
                echo -e "  use ${CYAN}--help${NC} for usage" >&2
                safe_exit 2
                ;;
        esac
    done
}

mobius_install__list_components() {
    echo ""
    echo -e "${BOLD}Available components${NC} (read from ${CYAN}${REPO_ROOT}components/${NC}):"
    echo ""
    if [[ ! -d "${REPO_ROOT}components" ]]; then
        echo -e "  ${YELLOW}(no components/ directory found — Phase D not yet shipped)${NC}"
        echo ""
        safe_exit 0
    fi
    local f
    shopt -s nullglob
    local found=0
    for f in "${REPO_ROOT}components"/*.yaml "${REPO_ROOT}components"/*.yml; do
        found=$((found+1))
        local id
        id="$(basename "$f")"
        id="${id%.yaml}"; id="${id%.yml}"
        echo -e "  ${CYAN}${id}${NC}  ${YELLOW}(${f#$REPO_ROOT})${NC}"
    done
    shopt -u nullglob
    [[ $found -eq 0 ]] && echo -e "  ${YELLOW}(components/ is empty — Phase D not yet shipped)${NC}"
    echo ""
    safe_exit 0
}

mobius_install__not_yet_implemented() {
    cat <<EOF >&2

${YELLOW}${BOLD}⚠ v0.1.0 scaffold — orchestrator logic lands in Phase B/C/D of the v1 plan.${NC}

What works today:
  - ${CYAN}--help${NC}, ${CYAN}-h${NC}      flag parsing + help text
  - ${CYAN}--list${NC}            walks the components/ directory (currently empty)

Coming next:
  - Phase B: shared bootstrap library (host prep, env seeding, manifest reader)
  - Phase C: per-component install flow (clone, seed .env, exec deploy.sh, health-check)
  - Phase D: component manifests for TILES, NVR, SMART_HOME

EOF
    safe_exit 1
}

mobius_install__run() {
    mobius_install__parse_args

    case "$MOBIUS_INSTALL__MODE" in
        list)
            mobius_install__list_components
            ;;
        menu|all|component)
            mobius_install__not_yet_implemented
            ;;
    esac
}

mobius_install__run
