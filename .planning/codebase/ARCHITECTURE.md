<!-- refreshed: 2026-08-21 -->
# Architecture

**Analysis Date:** 2026-08-21

## System Overview

```text
┌─────────────────────────────────────────────────────────────┐
│                     Operator Workstation                     │
│   `Makefile`, `config/inputs.sh`, `scripts/*.sh`              │
└───────────────┬───────────────────────┬───────────────────────┘
                │ terraform apply       │ ssh/scp
                ▼                       ▼
┌─────────────────────────┐   ┌─────────────────────────────────┐
│   Terraform (IaC layer) │   │   Deploy layer (`deploy/*.sh`)  │
│ `infra/terraform/`      │   │  bootstrap, deploy, backup,     │
│  envs/prod, modules/    │   │  restore, logs, status          │
│  hetzner-vps, globals   │   │                                  │
└───────────┬─────────────┘   └───────────────┬─────────────────┘
            │ provisions                       │ configures/operates
            ▼                                  ▼
┌─────────────────────────────────────────────────────────────┐
│               Hetzner Cloud VPS (`hcloud_server`)             │
│  cloud-init (`infra/cloud-init/user-data.yml.tpl`) installs   │
│  Docker, Tailscale, UFW, creates `openclaw` app user           │
└───────────────┬─────────────────────────────────────────────┘
                │ docker compose up
                ▼
┌─────────────────────────────────────────────────────────────┐
│  OpenClaw Docker Stack (external repo: openclaw-config)       │
│  `~/openclaw/docker-compose.yml` on VPS, `~/.openclaw` state  │
└─────────────────────────────────────────────────────────────┘
```

## Component Responsibilities

| Component | Responsibility | File |
|-----------|----------------|------|
| Terraform env (prod) | Declares provider, backend, wires the VPS module, exposes outputs | `infra/terraform/envs/prod/main.tf` |
| Terraform env vars | Input variable definitions/defaults for the prod environment | `infra/terraform/envs/prod/variables.tf` |
| Backend doc | Documents remote S3-compatible (Hetzner Object Storage) state backend | `infra/terraform/globals/backend.tf` |
| Provider/version pins | Pins Terraform and hcloud provider versions | `infra/terraform/globals/versions.tf` |
| Hetzner VPS module | Creates SSH key lookup, firewall, server, firewall attachment | `infra/terraform/modules/hetzner-vps/main.tf` |
| VPS module variables | Module input contract (project_name, ssh, ports, tailscale, etc.) | `infra/terraform/modules/hetzner-vps/variables.tf` |
| VPS module outputs | Exposes server IPs, ssh commands, firewall/server IDs | `infra/terraform/modules/hetzner-vps/outputs.tf` |
| Cloud-init template | First-boot provisioning: app user, Docker, Tailscale, UFW, dirs | `infra/cloud-init/user-data.yml.tpl` |
| Makefile | Single operator entrypoint wrapping terraform + deploy scripts | `Makefile` |
| Bootstrap script | One-time VPS setup: dirs, docker-compose, secrets, systemd backup timer | `deploy/bootstrap.sh` |
| Deploy script | Pulls latest image, restarts containers, prunes old images | `deploy/deploy.sh` |
| Backup script | Tars `~/.openclaw`, prunes backups >7 days, runs via systemd timer | `deploy/backup.sh` |
| Restore script | Restores a named backup archive to the VPS | `deploy/restore.sh` |
| Status/logs scripts | Read-only ops: container status, Tailscale status, log streaming | `deploy/status.sh`, `deploy/logs.sh` |
| SSH opts include | Shared SSH flag definitions sourced by deploy scripts | `deploy/ssh-opts.inc.sh` |
| Push scripts | Copy env/config files from local `openclaw-config` repo to VPS | `scripts/push-env.sh`, `scripts/push-config.sh` |
| Auth setup script | Configures Claude subscription auth via setup-token on VPS | `scripts/setup-auth.sh` |
| Local config | Operator secrets/inputs sourced before running Terraform/make | `config/inputs.sh` (gitignored), `config/inputs.example.sh` (template) |
| Local secrets | `.env` file pushed to VPS as OpenClaw runtime secrets | `secrets/openclaw.env` (gitignored), `secrets/openclaw.env.example` (template) |

## Pattern Overview

**Overall:** Infrastructure-as-Code + imperative shell ops layer — not an application codebase. Terraform provisions a single Hetzner Cloud VPS; a `Makefile`-orchestrated set of bash scripts then configures and operates a Docker Compose stack (OpenClaw) on that VPS over SSH.

**Key Characteristics:**
- Two-phase lifecycle: `terraform apply` (provision) then `make bootstrap && make deploy` (configure/run)
- No application source code lives in this repo — the actual OpenClaw service (`docker-compose.yml`, app config) lives in an external `openclaw-config` repository referenced via `CONFIG_DIR`
- All server mutation happens via SSH from the operator's machine; there is no CI/CD pipeline or remote agent
- Idempotent-ish bash: scripts check for existing state (e.g., docker-compose.yml presence) before acting
- Terraform state stored remotely in Hetzner Object Storage via S3-compatible backend (bucket `coter-tf-state`)

## Layers

**Provisioning layer (Terraform):**
- Purpose: Create/destroy cloud resources (server, firewall, SSH key)
- Location: `infra/terraform/`
- Contains: `envs/prod/*.tf` (root module), `modules/hetzner-vps/*.tf` (reusable VPS module), `globals/*.tf` (docs for backend/versions)
- Depends on: Hetzner Cloud API (`hcloud` provider), variables from `config/inputs.sh` (as `TF_VAR_*` env vars)
- Used by: `Makefile` targets `init`, `plan`, `apply`, `destroy`, `output`, `ip`, `fmt`, `validate`

**First-boot provisioning (cloud-init):**
- Purpose: One-shot OS-level setup executed by Hetzner on server creation
- Location: `infra/cloud-init/user-data.yml.tpl`
- Contains: package installs, Docker install, app user creation, UFW rules, Tailscale install/auth, directory scaffolding
- Depends on: Terraform template variables (`app_user`, `app_directory`, `enable_tailscale`, `tailscale_auth_key`, `additional_tcp_ports`)
- Used by: `hcloud_server.main.user_data` in `infra/terraform/modules/hetzner-vps/main.tf`

**Operator orchestration (Makefile):**
- Purpose: Single command surface for all terraform + deploy + ops actions
- Location: `Makefile`
- Contains: targets for terraform lifecycle, deploy lifecycle, SSH/tunnel utilities, Tailscale utilities
- Depends on: `config/inputs.sh` being sourced (sets `TF_VAR_*`, `CONFIG_DIR`, `GHCR_*`, etc.), `deploy/*.sh`, `scripts/*.sh`
- Used by: the operator directly (`make <target>`)

**Deploy/ops layer (bash over SSH):**
- Purpose: Configure the VPS after provisioning and operate the running stack
- Location: `deploy/`, `scripts/`
- Contains: bootstrap, deploy, backup, restore, status, logs, push-env, push-config, setup-auth
- Depends on: `deploy/ssh-opts.inc.sh` (shared SSH flags), Terraform outputs (`server_ip`), local secrets/config directories
- Used by: `Makefile` targets `bootstrap`, `deploy`, `push-env`, `push-config`, `setup-auth`, `backup-now`, `restore`, `logs`, `status`

## Data Flow

### Provisioning Path

1. Operator runs `source config/inputs.sh` then `make init` — sets `TF_VAR_*`/`AWS_*` env vars, initializes S3 backend (`Makefile:init`)
2. `make apply` — Terraform creates SSH key lookup, firewall, and `hcloud_server` with `user_data` rendered from `infra/cloud-init/user-data.yml.tpl` (`infra/terraform/modules/hetzner-vps/main.tf:71-97`)
3. Hetzner boots the VM; cloud-init runs `runcmd` steps: create `openclaw` user, install Docker, optionally install/auth Tailscale, configure UFW, create app directories (`infra/cloud-init/user-data.yml.tpl:42-118`)
4. Terraform outputs (`server_ip`, `ssh_command`, etc.) become available via `terraform output` (`infra/terraform/envs/prod/main.tf:90-138`)

### Bootstrap/Deploy Path

1. `make bootstrap` runs `deploy/bootstrap.sh $(SERVER_IP)` — verifies SSH, waits for cloud-init, logs in to GHCR, creates VPS directories, copies `docker-compose.yml` from `$CONFIG_DIR/docker/`, copies `backup.sh`, installs a systemd user timer for daily backups (`deploy/bootstrap.sh:85-213`)
2. Bootstrap conditionally invokes `scripts/push-env.sh` (if `secrets/openclaw.env` exists) and `scripts/push-config.sh` (if `$CONFIG_DIR/config` exists), and `scripts/setup-auth.sh` (if `CLAUDE_SETUP_TOKEN` set) (`deploy/bootstrap.sh:219-254`)
3. `make deploy` runs `deploy/deploy.sh $(SERVER_IP)` — SSHes in, pulls the latest Docker image via `docker compose pull`, pre-creates workspace bind-mount directories, conditionally enables the `sync` compose profile if `GIT_WORKSPACE_REPO`/`GIT_WORKSPACE_REMOTE` is set in `.env`, runs `docker compose up -d`, prunes old images, prints container status (`deploy/deploy.sh:62-159`)

**State Management:**
- Terraform state: remote, in Hetzner Object Storage S3-compatible bucket `coter-tf-state`, configured via `terraform init -backend-config="key=..."` (`infra/terraform/envs/prod/main.tf:29-45`)
- Application state: lives on the VPS filesystem under `~/.openclaw` (workspace, config) and is backed up via `deploy/backup.sh` to `~/backups/*.tar.gz` with 7-day retention, restorable via `deploy/restore.sh`
- No local application state — this repo is stateless aside from Terraform's `.terraform/` cache and lockfile (cleaned via `make clean`)

## Key Abstractions

**Terraform module (`hetzner-vps`):**
- Purpose: Encapsulates a reusable single-VPS-with-firewall pattern parameterized by environment
- Examples: `infra/terraform/modules/hetzner-vps/main.tf`, `variables.tf`, `outputs.tf`
- Pattern: Standard Terraform child module consumed once from `envs/prod/main.tf`; could be reused for additional envs (e.g., `envs/staging`) by copying the `envs/prod` directory

**Cloud-init templatefile:**
- Purpose: Injects Terraform variables into a YAML cloud-config using HCL `templatefile()` + `%{ if }/%{ for }` directives
- Examples: `infra/cloud-init/user-data.yml.tpl`, referenced at `infra/terraform/envs/prod/main.tf:77-83`
- Pattern: Declarative first-boot provisioning; conditional blocks toggle Tailscale install/auth and additional firewall ports

**Makefile as CLI facade:**
- Purpose: Normalizes all operations (terraform + ssh + docker ops) behind `make <target> [ENV=prod]`
- Examples: `Makefile`
- Pattern: `ENV` variable selects `TERRAFORM_DIR := infra/terraform/envs/$(ENV)`; `SERVER_IP` auto-resolves from `terraform output -raw server_ip` unless overridden

**SSH-opts include pattern:**
- Purpose: Centralizes SSH connection flags (batch mode, identity file, timeout) for reuse across deploy scripts
- Examples: `deploy/ssh-opts.inc.sh`, sourced by `deploy/deploy.sh:16`, `deploy/bootstrap.sh:17`
- Pattern: `source ".../ssh-opts.inc.sh"` at top of each deploy script that needs SSH

## Entry Points

**`make <target>`:**
- Location: `Makefile`
- Triggers: Operator invocation from repo root, e.g. `make apply`, `make bootstrap`, `make deploy`, `make status`
- Responsibilities: Dispatches to `terraform` CLI (cwd `infra/terraform/envs/$(ENV)`) or to `deploy/*.sh` / `scripts/*.sh` with `$(SERVER_IP)`

**`deploy/*.sh` scripts (standalone invocation):**
- Location: `deploy/bootstrap.sh`, `deploy/deploy.sh`, `deploy/backup.sh`, `deploy/restore.sh`, `deploy/status.sh`, `deploy/logs.sh`
- Triggers: Can be run directly, e.g. `./deploy/deploy.sh <VPS_IP>`, or via Make targets
- Responsibilities: Each is a self-contained bash script with `set -euo pipefail`, resolves `VPS_IP` from an arg or `terraform output`, then performs its operation over SSH

**`terraform apply` (root module):**
- Location: `infra/terraform/envs/prod/main.tf`
- Triggers: `make apply` or direct `terraform apply` inside the env dir
- Responsibilities: Provisions/updates the `hcloud_server`, firewall, and firewall attachment via the `vps` module

## Architectural Constraints

- **Threading:** Not applicable — this is IaC/bash, entirely sequential/synchronous script execution over SSH.
- **Global state:** Terraform remote state (S3 bucket `coter-tf-state`) is the single shared mutable state; local `config/inputs.sh` and `secrets/openclaw.env` are per-operator local state, never committed (gitignored).
- **Circular imports:** Not applicable (no application code/module graph).
- **Environment coupling:** Scripts assume a single `prod` environment (`TERRAFORM_DIR := infra/terraform/envs/$(ENV)`, default `ENV=prod`); adding another environment requires duplicating `infra/terraform/envs/prod/` as a sibling directory.
- **External dependency on `CONFIG_DIR`:** `deploy/bootstrap.sh` and `scripts/push-config.sh` hard-require a separate `openclaw-config` repository checked out locally at `$CONFIG_DIR`; this repo does not contain the actual OpenClaw app config or `docker-compose.yml` source.
- **Lifecycle `ignore_changes`:** `hcloud_server.main` ignores changes to `user_data` and `ssh_keys` after creation (`infra/terraform/modules/hetzner-vps/main.tf:91-96`), meaning cloud-init template edits do not re-provision an existing server — the server must be manually recreated or updated out-of-band.

## Anti-Patterns

### Remote script execution via heredoc (`ssh ... bash -s << 'REMOTE_SCRIPT'`)

**What happens:** `deploy/bootstrap.sh` and `deploy/deploy.sh` embed multi-line remote bash blocks inline via heredocs sent over `ssh ... bash -s`.
**Why it's wrong:** Errors inside the heredoc are harder to lint/test locally (`make validate` only runs `bash -n` on the outer script, not variable-substituted remote content); debugging requires re-running against a live VPS.
**Do this instead:** Treat these heredocs as the de facto "remote" scripts — when modifying them, manually copy them out and `bash -n` them, or keep changes minimal and test against a real VPS before merging.

### Hardcoded backend bucket/endpoint in `main.tf`

**What happens:** The S3 backend `bucket` and `endpoints.s3` values are hardcoded directly in `infra/terraform/envs/prod/main.tf:29-45`, with a comment saying "Replace with your endpoint."
**Why it's wrong:** Terraform backend blocks cannot use variables, so this is unavoidable to a degree, but it means the repo ships with a specific operator's bucket name/endpoint committed, which every fork must edit before `terraform init`.
**Do this instead:** Continue using `-backend-config="key=..."` partial configuration for the state key (already done via `TF_VAR_project_name` in `Makefile:init`), and document endpoint/bucket overrides clearly (already present in comments) rather than assuming any single value works for all deployments.

## Error Handling

**Strategy:** Fail-fast bash (`set -euo pipefail` in every `deploy/*.sh` and `scripts/*.sh`) combined with explicit precondition checks that print actionable error messages before exiting 1.

**Patterns:**
- Precondition guards with early `exit 1` and remediation instructions, e.g. missing `CONFIG_DIR` or `docker-compose.yml` (`deploy/bootstrap.sh:44-57`)
- SSH connectivity check before proceeding (`deploy/bootstrap.sh:89-97`)
- Non-fatal "best-effort" steps use `|| true` or `2>/dev/null` fallbacks (e.g., Tailscale-related systemd calls in cloud-init and bootstrap) so partial failures don't abort the whole run

## Cross-Cutting Concerns

**Logging:** Plain `echo`/`echo -e` with ANSI color codes for status output (`[OK]`, `[SKIP]`, `[WARN]`, `[ERROR]` prefixes) across all deploy scripts and the `Makefile`. No structured logging or log aggregation.

**Validation:** `make validate` runs `terraform validate` (with `-backend=false`) plus `bash -n` syntax-checks on all `deploy/*.sh` and `scripts/*.sh` files (`Makefile:64-70`). No automated tests beyond this.

**Authentication:** SSH key-based auth to the VPS (root and `openclaw` app user), Hetzner Cloud API token (`HCLOUD_TOKEN`/`TF_VAR_hcloud_token`), S3-compatible credentials for Terraform state (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`), GHCR PAT for private Docker image pulls (`GHCR_USERNAME`/`GHCR_TOKEN`), optional Tailscale auth key, optional Claude subscription setup token — all sourced from `config/inputs.sh` (gitignored) which is never committed.

---

*Architecture analysis: 2026-08-21*
