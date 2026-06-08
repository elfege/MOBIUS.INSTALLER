#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
# install-hooks.sh — Install git hooks from tracked copies
#
# Run after a fresh clone to restore hooks that live in .git/hooks/
# (which is not tracked by git).
#
# Usage: ./scripts/hooks/install-hooks.sh
# ─────────────────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK_SRC="$REPO_ROOT/scripts/hooks"
HOOK_DST="$REPO_ROOT/.git/hooks"

for hook in "$HOOK_SRC"/*; do
    name="$(basename "$hook")"
    # Skip this installer script
    [[ "$name" == "install-hooks.sh" ]] && continue
    cp "$hook" "$HOOK_DST/$name"
    chmod +x "$HOOK_DST/$name"
    echo "Installed: $name"
done

echo "Done. All hooks installed."
