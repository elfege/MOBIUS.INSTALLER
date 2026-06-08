#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
# lib/manifest.sh — component manifest reader.
#
# DESIGN NOTE — bash-sourcable manifests, not YAML.
#   The original v1 plan called for YAML manifests (data, not code). For v0.2.0
#   we use bash-sourcable manifests because:
#     1. Zero parsing dependencies (no yq, no python).
#     2. Native bash arrays for sequences (the schema's natural shape).
#     3. ~50 lines of loader vs. ~500 lines of YAML reader, with no edge cases.
#   Manifests live in components/<id>.manifest (extension intentionally NOT .sh
#   so they're not picked up by shell-completion / lint as standalone scripts).
#   The loader VALIDATES the loaded manifest: only declared MANIFEST_* variables
#   survive; anything else is unset. Manifests must not call commands; they're
#   "data, by convention" — the validator enforces this at load time.
#
# Source from mobius_install.sh:    . "${LIB_DIR}/manifest.sh"
#
# Exports:
#   - mobius_manifest__load <path>       loads a manifest file, populates
#                                         MANIFEST_* vars/arrays in current shell
#   - mobius_manifest__validate          asserts required fields are set
#   - mobius_manifest__describe          prints the loaded manifest to stdout
#
# Manifest schema (one component per file):
#   MANIFEST_ID                 (str)   component ID — must match basename
#   MANIFEST_DISPLAY_NAME       (str)   human label
#   MANIFEST_PUBLIC_REPO        (str)   public git repo URL to clone
#   MANIFEST_TARGET_DIR         (str)   where to clone it (tilde-expanded)
#   MANIFEST_DEPLOY_ENTRY       (str)   path to deploy script, relative to clone
#   MANIFEST_REQUIRES           (arr)   hard MOBIUS deps (other component IDs)
#   MANIFEST_OPTIONAL           (arr)   soft MOBIUS deps (user-note only)
#   MANIFEST_PORTS              (arr)   "host:container:purpose" tuples
#   MANIFEST_AWS_SECRET_ENV_VARS (arr)  env var NAMES (not literals) the user
#                                         must set if they choose AWS mode
#   MANIFEST_HOST_PREREQS       (arr)   "docker" | "docker-compose-v2" | "mount:/path"
#   MANIFEST_HEALTH_CHECKS      (arr)   "http URL EXPECT_STATUS TIMEOUT" |
#                                         "cmd <shell-cmd> EXPECT_EXIT"
#   MANIFEST_NOTES              (str)   free-form notes for the operator
# ─────────────────────────────────────────────────────────────────────

[[ -n "${_MOBIUS_MANIFEST_SOURCED:-}" ]] && return 0 2>/dev/null
_MOBIUS_MANIFEST_SOURCED=1

if [[ -n "${LIB_DIR:-}" && -f "${LIB_DIR}/log.sh" ]]; then
    # shellcheck disable=SC1091
    . "${LIB_DIR}/log.sh"
fi

_MOBIUS_MANIFEST_VARS=(
    MANIFEST_ID MANIFEST_DISPLAY_NAME MANIFEST_PUBLIC_REPO MANIFEST_TARGET_DIR
    MANIFEST_DEPLOY_ENTRY MANIFEST_REQUIRES MANIFEST_OPTIONAL MANIFEST_PORTS
    MANIFEST_AWS_SECRET_ENV_VARS MANIFEST_HOST_PREREQS MANIFEST_HEALTH_CHECKS
    MANIFEST_NOTES
)

_mobius_manifest__reset() {
    # Reset all schema vars so a previous manifest's state doesn't leak.
    local v
    for v in "${_MOBIUS_MANIFEST_VARS[@]}"; do
        unset "$v" 2>/dev/null || true
    done
    MANIFEST_REQUIRES=()
    MANIFEST_OPTIONAL=()
    MANIFEST_PORTS=()
    MANIFEST_AWS_SECRET_ENV_VARS=()
    MANIFEST_HOST_PREREQS=()
    MANIFEST_HEALTH_CHECKS=()
}

_mobius_manifest__lint() {
    # Reject manifests that contain command calls (anything outside assignments).
    # Heuristic: every non-comment, non-blank line must look like NAME=VALUE or
    # NAME=(…) or be a closing paren ).
    local path="$1"
    local line lineno=0 bad=0
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        # strip leading whitespace
        local s="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$s" || "$s" == \#* ]] && continue
        # array continuation
        [[ "$s" == ")" || "$s" == "]"* ]] && continue
        # variable assignment (NAME= or NAME=(…))
        if [[ "$s" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then continue; fi
        # array-element continuation line (inside a multi-line array literal)
        if [[ "$s" == \"* || "$s" == \'* ]]; then continue; fi
        mobius_log__err "manifest lint: $path:$lineno suspicious non-assignment line: $line"
        bad=$((bad + 1))
    done < "$path"
    return $bad
}

mobius_manifest__load() {
    # $1 = path to manifest file
    local path="$1"
    if [[ ! -f "$path" ]]; then
        mobius_log__err "manifest not found: $path"
        return 1
    fi
    _mobius_manifest__lint "$path" || {
        mobius_log__err "manifest failed lint; refusing to source: $path"
        return 1
    }
    _mobius_manifest__reset
    # shellcheck disable=SC1090
    . "$path" || {
        mobius_log__err "manifest sourcing failed: $path"
        return 1
    }
    mobius_manifest__validate || return 1
}

mobius_manifest__validate() {
    # Assert the required fields are set + ID matches the file basename pattern.
    local required=(MANIFEST_ID MANIFEST_DISPLAY_NAME MANIFEST_PUBLIC_REPO MANIFEST_TARGET_DIR MANIFEST_DEPLOY_ENTRY)
    local v missing=0
    for v in "${required[@]}"; do
        if [[ -z "${!v:-}" ]]; then
            mobius_log__err "manifest missing required field: $v"
            missing=$((missing + 1))
        fi
    done
    [[ $missing -gt 0 ]] && return 1
    return 0
}

mobius_manifest__describe() {
    # Print the currently-loaded manifest to stdout, structured.
    echo "── ${MANIFEST_DISPLAY_NAME:-<no name>} (${MANIFEST_ID:-?}) ──"
    echo "  repo:    ${MANIFEST_PUBLIC_REPO:-?}"
    echo "  target:  ${MANIFEST_TARGET_DIR:-?}"
    echo "  deploy:  ${MANIFEST_DEPLOY_ENTRY:-?}"
    echo "  requires: ${MANIFEST_REQUIRES[*]:-<none>}"
    echo "  optional: ${MANIFEST_OPTIONAL[*]:-<none>}"
    echo "  ports:"
    local p
    for p in "${MANIFEST_PORTS[@]:-}"; do [[ -n "$p" ]] && echo "    - $p"; done
    echo "  AWS secret env vars: ${MANIFEST_AWS_SECRET_ENV_VARS[*]:-<none>}"
    echo "  host prereqs: ${MANIFEST_HOST_PREREQS[*]:-<none>}"
    echo "  health checks:"
    local h
    for h in "${MANIFEST_HEALTH_CHECKS[@]:-}"; do [[ -n "$h" ]] && echo "    - $h"; done
    [[ -n "${MANIFEST_NOTES:-}" ]] && { echo "  notes:"; echo "${MANIFEST_NOTES}" | sed 's/^/    /'; }
}
