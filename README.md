# MOBIUS.INSTALLER

**Single entry-point installer for the MOBIUS suite.** Lets a fresh Ubuntu host
install all-or-part of the MOBIUS components with one command and no manual
intervention. Resolves inter-component dependencies, prompts once for AWS-vs-`.env`
secret mode, then orchestrates each component's existing `deploy.sh` chain.

> **Status:** v0.1.0 (scaffold). The orchestrator (`mobius_install.sh`), the
> shared bootstrap library (`lib/`), and the per-component manifests
> (`components/<id>.yaml`) are filled out across the phased v1 plan.

---

## Quick install

**Install everything (single host):**

```bash
curl -fsSL https://raw.githubusercontent.com/elfege/MOBIUS.INSTALLER/main/mobius_install.sh \
  | bash -s -- --all
```

**Install one component (`TILES`, `NVR`, `SMART_HOME`, …):**

```bash
curl -fsSL https://raw.githubusercontent.com/elfege/MOBIUS.<NAME>/main/install.sh | bash
```

Each project's `install.sh` is a thin bootstrap that pulls this installer with
the matching `--component=<ID>` preset, so the two entry paths converge to the
same code.

**Interactive menu (no flags):**

```bash
git clone https://github.com/elfege/MOBIUS.INSTALLER.git
cd MOBIUS.INSTALLER && ./mobius_install.sh
```

**Flags:**

| Flag | Effect |
|---|---|
| `--all` | Install every component declared in `components/` on this host, in dependency order |
| `--component=<ID>[,<ID>…]` | Install only the listed components (transitive deps still resolve) |
| `--list` | Print component IDs + their `requires:` graph and exit |
| `--dry-run` | Resolve deps and print the plan (ports, secrets, install order) without changing state |
| `--yes` | Skip the post-dry-run confirmation prompt (non-interactive) |
| `--help`, `-h` | Show usage |

Environment overrides:
- `MOBIUS_INSTALLER_REF=<git-ref>` — pin the installer to a specific tag or branch
  (default: latest `v*.*.*` tag). For installer-development only.

---

## What it actually does

1. **Pre-flight host bootstrap** — ensures `git`, `curl`, `docker.io`, and
   `docker-compose-v2` are installed; adds the current user to the `docker`
   group and self-re-execs under `sg docker` if the group was just added.
   Idempotent on re-run.
2. **Load manifests** — reads `components/<id>.yaml` for each requested
   component. Manifests are *data*, not code; declare public source URL, ports,
   transitive deps, host prerequisites, and health checks.
3. **Resolve dependency graph** — transitively pulls in hard `requires:` edges.
   Soft `optional:` edges become user notes, not failures.
4. **Dry-run** — prints the resolved plan (ports, AWS secret env-vars the user
   must have configured, install order). Aborts on port conflicts before any
   state changes.
5. **Per-component install** — clones the public repo into
   `~/__MOBIUS.INSTALL/<NAME>/`, seeds `.env` (prompting once for AWS Secrets
   Manager vs `.env`-only mode), then execs the component's own `deploy.sh`.
   The installer **never reimplements** what `deploy.sh` already does — it
   orchestrates. Health-checks per the manifest.
6. **Summary** — endpoints, container status, secret env-vars the user still
   needs to populate.

---

## Components covered in v1

| Component | Public repo | Hard MOBIUS deps |
|---|---|---|
| `TILES` | `elfege/MOBIUS.TILES` | (standalone) |
| `NVR` | `elfege/MOBIUS.NVR` | (standalone) |
| `SMART_HOME` | `elfege/MOBIUS.SMART_HOME` | (standalone) |

`PROXY` and `ANAMNESIS` manifests land in a later release.

---

## License

BSL 1.1 — see [LICENSE](LICENSE). Personal/non-commercial use is free; commercial
licensing at `elfege@elfege.com`.
