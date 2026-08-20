# Codebase Structure

**Analysis Date:** 2026-08-21

## Directory Layout

```
coter-terraform/
├── infra/
│   ├── terraform/
│   │   ├── envs/
│   │   │   └── prod/            # Root Terraform module for the prod environment
│   │   │       ├── main.tf      # Provider, backend, module wiring, outputs
│   │   │       └── variables.tf # Input variable declarations/defaults
│   │   ├── globals/
│   │   │   ├── backend.tf       # Documentation-only: explains the S3 backend
│   │   │   └── versions.tf      # Terraform/provider version pins (reference)
│   │   └── modules/
│   │       └── hetzner-vps/     # Reusable VPS+firewall Terraform module
│   │           ├── main.tf
│   │           ├── variables.tf
│   │           └── outputs.tf
│   └── cloud-init/
│       └── user-data.yml.tpl    # First-boot provisioning template (Docker, Tailscale, UFW, users)
├── deploy/                      # Bash scripts that run FROM the operator's machine, act via SSH
│   ├── ssh-opts.inc.sh          # Shared SSH flags, sourced by other deploy scripts
│   ├── bootstrap.sh             # One-time VPS setup (dirs, compose file, secrets, backup timer)
│   ├── deploy.sh                # Pull + restart the Docker Compose stack
│   ├── backup.sh                # Runs ON the VPS (via systemd timer or SSH) to tar ~/.openclaw
│   ├── restore.sh                # Restore a named backup archive
│   ├── status.sh                # Read-only VPS/container/Tailscale status check
│   └── logs.sh                  # Stream docker compose logs from the VPS
├── scripts/                     # Auxiliary operator scripts (secrets/config sync, auth)
│   ├── push-env.sh              # Copies secrets/openclaw.env to the VPS
│   ├── push-config.sh           # Copies $CONFIG_DIR/config to the VPS
│   └── setup-auth.sh            # Configures Claude subscription auth on the VPS
├── config/
│   ├── inputs.example.sh        # Template for operator input vars (committed)
│   └── inputs.sh                # Actual operator secrets/inputs (gitignored, NOT committed)
├── secrets/
│   └── openclaw.env.example     # Template for OpenClaw runtime env pushed to VPS (committed)
│                                 # secrets/openclaw.env itself is gitignored, NOT committed
├── .planning/                   # GSD planning artifacts (codebase docs, phases, etc.)
├── .claude/ .codex/ .cursor/    # GSD framework tooling — agents, commands, skills, hooks (not app code)
├── Makefile                     # Single CLI entrypoint: make <target> [ENV=prod]
├── README.md                    # Project overview / usage docs
├── CHANGELOG.md, CONTRIBUTING.md, CODE_OF_CONDUCT.md, SECURITY.md, LICENSE
```

## Directory Purposes

**`infra/terraform/envs/prod/`:**
- Purpose: Root Terraform module — the only module actually `terraform init`/`apply`'d
- Contains: `main.tf` (provider config, S3 backend block, module invocation, outputs), `variables.tf` (declarations consumed via `TF_VAR_*` env vars)
- Key files: `main.tf`, `variables.tf`

**`infra/terraform/globals/`:**
- Purpose: Reference-only documentation for backend and version configuration (not directly used by `terraform init`, since the actual backend block must live in the root module per Terraform's constraints)
- Contains: `backend.tf`, `versions.tf`
- Key files: `backend.tf` (explains S3-compatible Hetzner Object Storage state backend)

**`infra/terraform/modules/hetzner-vps/`:**
- Purpose: Reusable child module encapsulating a single Hetzner Cloud VPS + firewall + SSH key lookup
- Contains: `main.tf` (resources: `hcloud_firewall`, `hcloud_server`, `hcloud_firewall_attachment`, `data.hcloud_ssh_key`), `variables.tf` (module inputs), `outputs.tf` (module outputs consumed by `envs/prod/main.tf`)
- Key files: `main.tf`

**`infra/cloud-init/`:**
- Purpose: VM first-boot provisioning, rendered as an HCL `templatefile()` and passed as `user_data`
- Contains: `user-data.yml.tpl` — cloud-config YAML with `write_files` and `runcmd` sections plus `%{ if }/%{ for }` template directives for conditional Tailscale/firewall-port logic
- Key files: `user-data.yml.tpl`

**`deploy/`:**
- Purpose: Operator-run bash scripts that configure and operate the already-provisioned VPS over SSH
- Contains: One script per operation (bootstrap, deploy, backup, restore, status, logs) plus a shared `ssh-opts.inc.sh` include
- Key files: `bootstrap.sh` (initial setup, 283 lines), `deploy.sh` (pull+restart, 159 lines), `backup.sh` (also runs ON the VPS via systemd timer)

**`scripts/`:**
- Purpose: Secondary operator scripts not tied to the core provision/deploy lifecycle — secrets/config sync and auth setup
- Contains: `push-env.sh`, `push-config.sh`, `setup-auth.sh`
- Key files: `push-env.sh` (130 lines), `push-config.sh` (117 lines), `setup-auth.sh` (121 lines)

**`config/`:**
- Purpose: Operator-local input variables sourced before running `make`/`terraform` commands
- Contains: `inputs.example.sh` (committed template), `inputs.sh` (real values — gitignored)
- Key files: `inputs.example.sh` documents every required/optional `TF_VAR_*` and script env var

**`secrets/`:**
- Purpose: OpenClaw application runtime secrets pushed to the VPS's `.env` via `scripts/push-env.sh`
- Contains: `openclaw.env.example` (committed template), `openclaw.env` (real secrets — gitignored)

**`.planning/`:**
- Purpose: GSD workflow planning artifacts (phase plans, codebase maps, roadmap) — not application code
- Contains: `codebase/` (this directory's own output: STACK.md, ARCHITECTURE.md, etc.)

**`.claude/`, `.codex/`, `.cursor/`:**
- Purpose: GSD (Get-Shit-Done) framework tooling — slash commands, subagents, skills, hooks for AI-assisted development workflow across three AI CLI tools (Claude Code, Codex, Cursor)
- Contains: `agents/*.md`, `commands/*.md` or `skills/*/`, `hooks/*.js`, `gsd-core/` (shared templates/workflows/references), `scripts/*.cjs`
- Not application/infrastructure code — irrelevant to the Terraform/deploy architecture itself

## Key File Locations

**Entry Points:**
- `Makefile`: Primary operator CLI (`make <target> [ENV=prod]`)
- `infra/terraform/envs/prod/main.tf`: Terraform root module entry point

**Configuration:**
- `config/inputs.sh` (gitignored, from `config/inputs.example.sh`): Hetzner token, S3 backend creds, SSH CIDRs/fingerprint, `CONFIG_DIR`, GHCR creds, Tailscale settings
- `secrets/openclaw.env` (gitignored, from `secrets/openclaw.env.example`): OpenClaw app runtime env vars pushed to the VPS

**Core Logic:**
- `infra/terraform/modules/hetzner-vps/main.tf`: All cloud resource definitions
- `infra/cloud-init/user-data.yml.tpl`: All VM first-boot provisioning logic
- `deploy/bootstrap.sh`, `deploy/deploy.sh`: Core deploy lifecycle logic

**Testing:**
- No automated test suite exists. `make validate` performs `terraform validate` (`Makefile:63-70`) and `bash -n` syntax checks on `deploy/*.sh` and `scripts/*.sh`.

## Naming Conventions

**Files:**
- Terraform files: standard `main.tf` / `variables.tf` / `outputs.tf` triad per module/environment
- Shell scripts: lowercase-hyphenated verbs matching their action, e.g. `push-env.sh`, `setup-auth.sh`, `backup.sh`
- Shared shell includes use `.inc.sh` suffix (e.g., `ssh-opts.inc.sh`) to signal "sourced, not executed directly"
- Templates use `.example` suffix for committed placeholders of gitignored real files (`inputs.example.sh` → `inputs.sh`, `openclaw.env.example` → `openclaw.env`)
- Cloud-init template uses `.yml.tpl` suffix (YAML rendered via Terraform `templatefile()`)

**Directories:**
- `envs/<environment>/` pattern for Terraform root modules (currently only `prod`); add new environments as sibling directories (e.g., `envs/staging/`)
- `modules/<module-name>/` for reusable Terraform child modules
- Top-level nouns describe function: `infra/` (provisioning), `deploy/` (operate the running stack), `scripts/` (secondary ops), `config/`+`secrets/` (local-only inputs)

## Where to Add New Code

**New Terraform environment (e.g., staging):**
- Copy `infra/terraform/envs/prod/` to `infra/terraform/envs/staging/`, adjust `environment = "staging"` in the module call and any environment-specific variable defaults; run with `make apply ENV=staging`

**New Terraform-managed resource type:**
- If it belongs to the VPS module's concern (firewall rules, server config): edit `infra/terraform/modules/hetzner-vps/main.tf` + `variables.tf` + `outputs.tf`
- If it's a genuinely new infrastructure component (e.g., a second server, a DNS zone): add a new module under `infra/terraform/modules/<name>/` and wire it into `infra/terraform/envs/prod/main.tf`

**New deploy/ops action (e.g., a new `make` target that SSHes into the VPS):**
- Add a new script to `deploy/` (source `deploy/ssh-opts.inc.sh` for SSH flags) or `scripts/` if it's a secrets/config/auth utility
- Add a corresponding target + `.PHONY` entry + help text line in `Makefile`

**New cloud-init provisioning step:**
- Edit `infra/cloud-init/user-data.yml.tpl` `runcmd`/`write_files` sections; remember `hcloud_server.main` has `lifecycle.ignore_changes = [user_data]`, so existing servers won't pick up changes without manual recreation

**New required secret/config variable:**
- Add it to both `config/inputs.example.sh` (documented, committed) and instruct users to add the real value to their local `config/inputs.sh`; if it's a Terraform variable, also declare it in `infra/terraform/envs/prod/variables.tf` and the module's `variables.tf`

## Special Directories

**`infra/terraform/envs/prod/.terraform/` (not present in listing, created by `terraform init`):**
- Purpose: Terraform provider plugin cache and backend config
- Generated: Yes
- Committed: No (removed via `make clean`)

**`.claude/`, `.codex/`, `.cursor/`:**
- Purpose: GSD AI-workflow framework installation (agents, commands/skills, hooks) — orthogonal to the Terraform/deploy architecture
- Generated: Partially (installed/updated by the GSD tool itself)
- Committed: Yes (framework config and skill definitions are checked in)

**`.planning/`:**
- Purpose: GSD planning documents including this codebase map
- Generated: Yes, by GSD commands (`/gsd-map-codebase` etc.)
- Committed: Typically yes, as project planning history

---

*Structure analysis: 2026-08-21*
