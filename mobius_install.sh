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
# ║      │ (apt+docker+sg)  │   │ components/*     │   │ + dry-run        │              ║
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
# ║    --yes, -y                       Skip the post-dry-run confirm prompt              ║
# ║    --no-bootstrap                  Skip the host-prep step (deps already present)    ║
# ║    --help, -h                      Show usage                                        ║
# ║                                                                                      ║
# ║  ENV OVERRIDES:                                                                      ║
# ║    MOBIUS_INSTALLER_REF            Pin the installer ref (default: latest v*.*.*)    ║
# ║    MOBIUS_INSTALL_ROOT             Where to clone components (default: ~/__MOBIUS.INSTALL) ║
# ║    <ID>_USE_AWS_SECRETS=true       Pre-set AWS mode for component <ID>               ║
# ║    <ID>_AWS_PROFILE / <ID>_AWS_SECRET_NAMES   Pre-seed AWS env-mode .env             ║
# ║                                                                                      ║
# ║  CANONICAL EXCEPTIONS (documented):                                                  ║
# ║    S.2.1  source_global_env replaced by S.2.18 portable helper sourcing (lib/).     ║
# ║    S.2.3  PAUSE_FILE — not applicable to a one-shot installer.                      ║
# ║    S.2.17 builtin cd used for SCRIPT_DIR resolution.                                 ║
# ╚══════════════════════════════════════════════════════════════════════════════════════╝

[[ -t 1 ]] && clear

set -u

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_R_PATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="${SCRIPT_R_PATH%${SCRIPT_NAME}}"
REPO_ROOT="$(builtin cd "${SCRIPT_DIR}" && pwd)"
LIB_DIR="${REPO_ROOT}/lib"
COMPONENTS_DIR="${REPO_ROOT}/components"

# Source the shared bootstrap library (S.2.18 portable sourcing).
for f in log.sh bootstrap.sh env_seed.sh manifest.sh; do
    if [[ -f "${LIB_DIR}/${f}" ]]; then
        # shellcheck disable=SC1090
        . "${LIB_DIR}/${f}"
    else
        echo "✗ missing required library: ${LIB_DIR}/${f}" >&2
        exit 1
    fi
done

########################################################################
MOBIUS_INSTALL__ARGS=("$@")
MOBIUS_INSTALL__MODE="menu"            # menu | all | component | list
MOBIUS_INSTALL__COMPONENTS=()          # explicit IDs from --component=
MOBIUS_INSTALL__DRY_RUN=false
MOBIUS_INSTALL__YES=false
MOBIUS_INSTALL__SKIP_BOOTSTRAP=false
MOBIUS_INSTALL__INSTALL_ROOT="${MOBIUS_INSTALL_ROOT:-${HOME}/__MOBIUS.INSTALL}"
MOBIUS_INSTALL__RESOLVED=()            # final ordered install list (set by resolve)
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

${BOLD}${CYAN}Usage:${NC} $0 [--all | --component=<ID>[,<ID>...]] [--dry-run] [--yes] [--no-bootstrap] [--help|-h]

  Install all-or-part of the MOBIUS suite on this host.

${BOLD}Flags:${NC}
  ${CYAN}--all${NC}                            Install every component (transitive deps resolve)
  ${CYAN}--component=<ID>[,<ID>...]${NC}      Install specific component(s). Comma-separated.
  ${CYAN}--list${NC}                           Print component IDs + their dependency edges
  ${CYAN}--dry-run${NC}                        Resolve deps + print the install plan only
  ${CYAN}--yes${NC}, ${CYAN}-y${NC}                       Skip the post-dry-run confirmation prompt
  ${CYAN}--no-bootstrap${NC}                   Skip host prep (assume docker+git+curl already present)
  ${CYAN}--help${NC}, ${CYAN}-h${NC}                       Show this message

${BOLD}Environment:${NC}
  ${CYAN}MOBIUS_INSTALLER_REF${NC}             Pin installer to a git ref (default: latest v*.*.* tag)
  ${CYAN}MOBIUS_INSTALL_ROOT${NC}              Clone target dir (default: ~/__MOBIUS.INSTALL)
  ${CYAN}<ID>_USE_AWS_SECRETS=true${NC}        Pre-set AWS Secrets Manager mode for <ID>
  ${CYAN}<ID>_AWS_PROFILE / _SECRET_NAMES${NC} Pre-seed the AWS-mode .env stub for <ID>

${BOLD}Examples:${NC}
  ${GREEN}$0 --all --yes${NC}                              Install everything, non-interactive
  ${GREEN}$0 --component=NVR --dry-run${NC}                Show NVR install plan, no changes
  ${GREEN}$0 --component=TILES,SMART_HOME${NC}             Install two components (interactive)
  ${GREEN}$0 --list${NC}                                   List available components

${BOLD}Direct (curl|bash):${NC}
  ${GREEN}curl -fsSL https://raw.githubusercontent.com/elfege/MOBIUS.INSTALLER/main/mobius_install.sh \\
    | bash -s -- --all --yes${NC}

EOF
    safe_exit 0
}

mobius_install__parse_args() {
    local a
    for a in "${MOBIUS_INSTALL__ARGS[@]}"; do
        case "$a" in
            --all)              MOBIUS_INSTALL__MODE="all" ;;
            --component=*)      MOBIUS_INSTALL__MODE="component"
                                 IFS=',' read -r -a MOBIUS_INSTALL__COMPONENTS <<< "${a#--component=}" ;;
            --list)             MOBIUS_INSTALL__MODE="list" ;;
            --dry-run)          MOBIUS_INSTALL__DRY_RUN=true ;;
            --yes|-y)           MOBIUS_INSTALL__YES=true ;;
            --no-bootstrap)     MOBIUS_INSTALL__SKIP_BOOTSTRAP=true ;;
            --help|-h)          mobius_install__show_help ;;
            *)
                mobius_log__err "unknown flag: $a"
                mobius_log__info "  use --help for usage"
                safe_exit 2 ;;
        esac
    done
}

# ──── component discovery + dep resolution ─────────────────────────

_mobius_install__list_manifests() {
    # Print component IDs in alphabetical order (matches manifest basenames).
    [[ ! -d "$COMPONENTS_DIR" ]] && return 0
    local f
    shopt -s nullglob
    for f in "${COMPONENTS_DIR}"/*.manifest; do
        basename "$f" .manifest
    done
    shopt -u nullglob
}

_mobius_install__manifest_path() {
    # $1 = component ID → echo absolute path to manifest, or empty if missing.
    local id="$1"
    local p="${COMPONENTS_DIR}/${id}.manifest"
    [[ -f "$p" ]] && echo "$p"
}

mobius_install__list_action() {
    echo ""
    mobius_log__step "Available components in ${CYAN}${COMPONENTS_DIR}${NC}:"
    echo ""
    local ids
    ids="$(_mobius_install__list_manifests)"
    if [[ -z "$ids" ]]; then
        mobius_log__warn "no manifests found (Phase D not yet shipped?)"
        echo ""
        safe_exit 0
    fi
    local id
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        if mobius_manifest__load "$(_mobius_install__manifest_path "$id")" 2>/dev/null; then
            local req="${MANIFEST_REQUIRES[*]:-}"
            local opt="${MANIFEST_OPTIONAL[*]:-}"
            printf "  ${CYAN}%-14s${NC} ${BOLD}%s${NC}\n" "$id" "${MANIFEST_DISPLAY_NAME:-?}"
            [[ -n "$req" ]] && printf "    requires: %s\n" "$req"
            [[ -n "$opt" ]] && printf "    optional: %s\n" "$opt"
        else
            printf "  ${YELLOW}%-14s${NC} <manifest invalid>\n" "$id"
        fi
    done <<< "$ids"
    echo ""
    safe_exit 0
}

# Transitive-dependency resolution via DFS with topological sort.
# Sets MOBIUS_INSTALL__RESOLVED to dep-order (deps first).
_mobius_install__visited=()
_mobius_install__visiting=()

_mobius_install__resolve_one() {
    local id="$1"
    # cycle detection
    local v
    for v in "${_mobius_install__visiting[@]:-}"; do
        [[ "$v" == "$id" ]] && { mobius_log__err "dependency cycle through $id"; return 1; }
    done
    # already resolved
    for v in "${MOBIUS_INSTALL__RESOLVED[@]:-}"; do
        [[ "$v" == "$id" ]] && return 0
    done

    local mpath
    mpath="$(_mobius_install__manifest_path "$id")"
    if [[ -z "$mpath" ]]; then
        mobius_log__err "no manifest for component '$id' in ${COMPONENTS_DIR}"
        return 1
    fi

    _mobius_install__visiting+=("$id")
    mobius_manifest__load "$mpath" || { mobius_log__err "manifest load failed: $id"; return 1; }
    local dep
    for dep in "${MANIFEST_REQUIRES[@]:-}"; do
        [[ -z "$dep" ]] && continue
        _mobius_install__resolve_one "$dep" || return 1
    done
    # pop from visiting
    local i new=()
    for i in "${_mobius_install__visiting[@]:-}"; do [[ "$i" != "$id" ]] && new+=("$i"); done
    _mobius_install__visiting=("${new[@]}")

    MOBIUS_INSTALL__RESOLVED+=("$id")
}

mobius_install__resolve() {
    # Populate MOBIUS_INSTALL__RESOLVED based on the chosen mode.
    MOBIUS_INSTALL__RESOLVED=()
    _mobius_install__visited=()
    _mobius_install__visiting=()

    local targets=()
    case "$MOBIUS_INSTALL__MODE" in
        all)
            local id
            while IFS= read -r id; do [[ -n "$id" ]] && targets+=("$id"); done < <(_mobius_install__list_manifests)
            ;;
        component)
            targets=("${MOBIUS_INSTALL__COMPONENTS[@]}")
            ;;
        *)
            mobius_log__err "internal: resolve called in mode '$MOBIUS_INSTALL__MODE'"
            return 1 ;;
    esac

    if [[ ${#targets[@]} -eq 0 ]]; then
        mobius_log__err "no components selected"
        return 1
    fi

    local t
    for t in "${targets[@]}"; do
        _mobius_install__resolve_one "$t" || return 1
    done
}

# ──── dry-run report ────────────────────────────────────────────────

mobius_install__print_plan() {
    echo ""
    mobius_log__step "Install plan"
    echo "  ${BOLD}install root:${NC} ${MOBIUS_INSTALL__INSTALL_ROOT}"
    echo "  ${BOLD}order:${NC}        ${MOBIUS_INSTALL__RESOLVED[*]}"
    echo ""

    local id
    for id in "${MOBIUS_INSTALL__RESOLVED[@]}"; do
        mobius_manifest__load "$(_mobius_install__manifest_path "$id")" || continue
        echo "  ── ${CYAN}${id}${NC} (${MANIFEST_DISPLAY_NAME})"
        echo "       repo:   ${MANIFEST_PUBLIC_REPO}"
        echo "       target: ${MOBIUS_INSTALL__INSTALL_ROOT}/${id}"
        echo "       deploy: ${MANIFEST_DEPLOY_ENTRY}"
        [[ ${#MANIFEST_PORTS[@]:-0} -gt 0 ]] && echo "       ports:  ${MANIFEST_PORTS[*]}"
        [[ ${#MANIFEST_AWS_SECRET_ENV_VARS[@]:-0} -gt 0 ]] \
            && echo "       AWS env vars (if AWS mode): ${MANIFEST_AWS_SECRET_ENV_VARS[*]}"
        [[ -n "${MANIFEST_NOTES:-}" ]] \
            && echo "${MANIFEST_NOTES}" | sed 's/^/       NOTE: /'
        echo ""
    done
}

mobius_install__confirm() {
    $MOBIUS_INSTALL__YES && return 0
    if ! : >/dev/tty 2>/dev/null; then
        # No tty available — under curl|bash, default to abort unless --yes.
        mobius_log__err "no tty for confirmation; re-run with --yes for non-interactive install"
        return 1
    fi
    local answer=""
    read -r -p "Proceed with this plan? (yes/no): " answer </dev/tty 2>/dev/tty || true
    [[ "$answer" =~ ^(yes|YES|y|Y)$ ]]
}

# ──── per-component install ─────────────────────────────────────────

mobius_install__clone_component() {
    # $1 = component ID. Manifest already loaded.
    local id="$1"
    local target="${MOBIUS_INSTALL__INSTALL_ROOT}/${id}"
    if [[ -d "${target}/.git" ]]; then
        mobius_log__ok "${id}: existing clone at ${target}"
        return 0
    fi
    if [[ -e "$target" ]]; then
        mobius_log__err "${id}: ${target} exists but is not a git checkout"
        return 1
    fi
    mobius_log__step "${id}: cloning ${MANIFEST_PUBLIC_REPO} → ${target}"
    mkdir -p "$(dirname "$target")"
    git clone --depth 50 "$MANIFEST_PUBLIC_REPO" "$target" || {
        mobius_log__err "${id}: clone failed"
        return 1
    }
    mobius_log__ok "${id}: cloned"
}

mobius_install__deploy_component() {
    # $1 = component ID. Manifest loaded.
    local id="$1"
    local target="${MOBIUS_INSTALL__INSTALL_ROOT}/${id}"
    local entry="${MANIFEST_DEPLOY_ENTRY}"
    if [[ ! -x "${target}/${entry}" ]]; then
        mobius_log__err "${id}: deploy entry not executable: ${target}/${entry}"
        return 1
    fi
    mobius_log__step "${id}: running ${entry}"
    (
        builtin cd "$target" && "./${entry}" --no-prune
    ) || {
        mobius_log__err "${id}: deploy.sh failed"
        return 1
    }
    mobius_log__ok "${id}: deploy.sh completed"
}

mobius_install__health_check_one() {
    # Parse and execute a single health-check directive.
    # Forms:
    #   "http <URL> <expect_status> <timeout_seconds>"
    #   "cmd <shell-command> <expect_exit>"
    local spec="$1"
    local kind="${spec%% *}"
    case "$kind" in
        http)
            local url status timeout
            read -r _ url status timeout <<< "$spec"
            local actual
            actual="$(curl -s -o /dev/null -w '%{http_code}' --max-time "${timeout:-30}" "$url" 2>/dev/null || echo 000)"
            if [[ "$actual" == "$status" ]]; then
                mobius_log__ok "  health http $url → $actual"
                return 0
            fi
            mobius_log__err "  health http $url → $actual (expected $status)"
            return 1
            ;;
        cmd)
            local rest expect
            rest="${spec#cmd }"
            # Last token = expected exit code
            expect="${rest##* }"
            rest="${rest% $expect}"
            bash -c "$rest" >/dev/null 2>&1
            local rc=$?
            if [[ "$rc" -eq "$expect" ]]; then
                mobius_log__ok "  health cmd '$rest' → $rc"
                return 0
            fi
            mobius_log__err "  health cmd '$rest' → $rc (expected $expect)"
            return 1
            ;;
        *)
            mobius_log__warn "  health: unknown directive kind '$kind'"
            return 0
            ;;
    esac
}

mobius_install__health_checks() {
    local id="$1"
    [[ ${#MANIFEST_HEALTH_CHECKS[@]:-0} -eq 0 ]] && return 0
    mobius_log__step "${id}: health checks"
    local h fails=0
    for h in "${MANIFEST_HEALTH_CHECKS[@]}"; do
        [[ -z "$h" ]] && continue
        mobius_install__health_check_one "$h" || fails=$((fails + 1))
    done
    [[ $fails -gt 0 ]] && { mobius_log__warn "${id}: $fails health check(s) failed"; return 1; }
    mobius_log__ok "${id}: all health checks passed"
}

mobius_install__install_one() {
    local id="$1"
    mobius_manifest__load "$(_mobius_install__manifest_path "$id")" || return 1
    echo ""
    mobius_log__step "═══ Installing ${id} (${MANIFEST_DISPLAY_NAME}) ═══"
    mobius_install__clone_component "$id" || return 1
    mobius_env_seed__for_component "$id" "${MOBIUS_INSTALL__INSTALL_ROOT}/${id}" || return 1
    mobius_install__deploy_component "$id" || return 1
    mobius_install__health_checks "$id" || true  # non-fatal in v1; flagged only
}

# ──── interactive menu ─────────────────────────────────────────────

mobius_install__menu() {
    if ! : >/dev/tty 2>/dev/null; then
        mobius_log__err "no tty — pass --all or --component=<ID>[,<ID>...] for non-interactive"
        safe_exit 2
    fi
    echo ""
    mobius_log__step "MOBIUS installer — interactive"
    local ids; ids="$(_mobius_install__list_manifests)"
    if [[ -z "$ids" ]]; then
        mobius_log__warn "no component manifests found (Phase D not yet shipped?)"
        safe_exit 0
    fi
    local arr=()
    while IFS= read -r line; do [[ -n "$line" ]] && arr+=("$line"); done <<< "$ids"
    echo "  ${BOLD}A.${NC} install all (${arr[*]})"
    local i=1 id
    for id in "${arr[@]}"; do
        printf "  ${BOLD}%d.${NC} %s\n" "$i" "$id"
        i=$((i + 1))
    done
    echo ""
    local answer=""
    read -r -p "Choose [A / number / comma-list of numbers]: " answer </dev/tty 2>/dev/tty || true
    case "$answer" in
        A|a|all|ALL)
            MOBIUS_INSTALL__MODE="all" ;;
        *)
            local nums=() picked=()
            IFS=',' read -r -a nums <<< "$answer"
            local n
            for n in "${nums[@]}"; do
                n="${n//[[:space:]]/}"
                [[ "$n" =~ ^[0-9]+$ ]] || { mobius_log__err "invalid: $n"; safe_exit 2; }
                local idx=$((n - 1))
                [[ $idx -lt 0 || $idx -ge ${#arr[@]} ]] && { mobius_log__err "out of range: $n"; safe_exit 2; }
                picked+=("${arr[$idx]}")
            done
            [[ ${#picked[@]} -eq 0 ]] && { mobius_log__err "no selection"; safe_exit 2; }
            MOBIUS_INSTALL__MODE="component"
            MOBIUS_INSTALL__COMPONENTS=("${picked[@]}") ;;
    esac
}

# ──── execution ────────────────────────────────────────────────────

mobius_install__run() {
    mobius_install__parse_args

    case "$MOBIUS_INSTALL__MODE" in
        list)
            mobius_install__list_action ;;
        menu)
            mobius_install__menu ;;
    esac

    # Resolve dependencies.
    mobius_install__resolve || safe_exit 1
    mobius_install__print_plan

    if $MOBIUS_INSTALL__DRY_RUN; then
        mobius_log__ok "Dry-run complete; no state changed."
        safe_exit 0
    fi

    if ! mobius_install__confirm; then
        mobius_log__warn "Aborted by user."
        safe_exit 1
    fi

    # Host bootstrap (unless skipped).
    if ! $MOBIUS_INSTALL__SKIP_BOOTSTRAP; then
        mobius_bootstrap__run "$0" "${MOBIUS_INSTALL__ARGS[@]}" || safe_exit 1
    fi

    # Install each component in resolved order.
    mkdir -p "${MOBIUS_INSTALL__INSTALL_ROOT}"
    local id ok=0 fail=0
    for id in "${MOBIUS_INSTALL__RESOLVED[@]}"; do
        if mobius_install__install_one "$id"; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
            mobius_log__err "${id}: install failed; continuing with remaining components"
        fi
    done

    echo ""
    mobius_log__step "Summary"
    mobius_log__ok  "${ok} component(s) installed"
    [[ $fail -gt 0 ]] && mobius_log__err "${fail} component(s) failed"
    echo ""
    safe_exit $(( fail > 0 ? 1 : 0 ))
}

mobius_install__run
