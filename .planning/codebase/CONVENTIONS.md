# Coding Conventions

**Analysis Date:** 2026-08-21

## Project Type

This is an infrastructure-as-code repository (Terraform + Bash), not an application codebase. There is no application source language (JS/Python/etc.) — conventions below cover HCL (Terraform) and Bash shell scripts, the two languages present.

## Naming Patterns

**Terraform files:**
- Standard HCL split by concern: `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, `backend.tf` (e.g. `infra/terraform/modules/hetzner-vps/main.tf`, `infra/terraform/globals/backend.tf`)
- Environment-specific stacks live under `infra/terraform/envs/<env>/` (e.g. `infra/terraform/envs/prod/main.tf`)
- Reusable logic lives under `infra/terraform/modules/<module-name>/` (e.g. `infra/terraform/modules/hetzner-vps/`)

**Terraform resources/variables:**
- Resource names use `snake_case`: `hcloud_firewall.main`, `hcloud_server.main` (`infra/terraform/modules/hetzner-vps/main.tf`)
- A single logical resource per type is usually named `main` (e.g. `data "hcloud_ssh_key" "main"`)
- Variables use `snake_case` and are grouped by purpose with banner comments (`# === Required Variables ===`, `# === Server Configuration ===`) in `infra/terraform/modules/hetzner-vps/variables.tf`
- Outputs use `snake_case` and always carry a `description` field (`infra/terraform/envs/prod/main.tf`)

**Shell scripts:**
- Located in `scripts/` (operator utilities: `setup-auth.sh`, `push-config.sh`, `push-env.sh`) and `deploy/` (lifecycle scripts: `deploy.sh`, `backup.sh`, `restore.sh`, `bootstrap.sh`, `status.sh`, `logs.sh`)
- File names are `kebab-case.sh`
- Shell variables use `UPPER_SNAKE_CASE` for globals/config (`VPS_USER`, `SSH_OPTS`, `TERRAFORM_DIR`, `CLAUDE_SETUP_TOKEN`)

## Code Style

**Terraform (HCL):**
- Formatted with `terraform fmt -recursive infra/` (enforced via `make fmt` and CI `terraform fmt -check -recursive`)
- Section banners use a consistent comment style:
  ```hcl
  # ============================================
  # Section Name
  # ============================================
  ```
  Used throughout `main.tf`, `variables.tf`, `outputs.tf` files to group related resources/variables.
- Every `variable` block includes a `description`; most include an explicit `type`
- Sensitive/config-heavy variables list defaults and constraints together (`server_location` defaults to `"nbg1"` with a `validation` block restricting to real Hetzner locations)

**Bash:**
- Every script starts with `#!/bin/bash` and `set -euo pipefail` (see `scripts/setup-auth.sh:1,21`)
- Scripts open with a large header comment block describing Purpose, Usage, and behavior:
  ```bash
  # =============================================================================
  # OpenClaw Setup Auth Script
  # =============================================================================
  # Purpose: ...
  # Usage: ./scripts/setup-auth.sh [VPS_IP]
  # =============================================================================
  ```
- Sections within scripts are separated with `# --- Section Name ---` style comment dividers
- Shared SSH options are sourced from a common include: `source ".../deploy/ssh-opts.inc.sh"` rather than duplicated per script

**Linting:**
- ShellCheck runs in CI against `./deploy` and `./scripts` directories (severity: warning) — see `.github/workflows/shellcheck.yml`
- No HCL linter beyond `terraform fmt -check` and `terraform validate` (see `.github/workflows/terraform.yml`)

## Validation & Guardrails

**Terraform variable validation:**
- Use `validation` blocks to enforce constraints inline rather than relying on documentation, e.g.:
  ```hcl
  variable "environment" {
    type = string
    validation {
      condition     = contains(["dev", "staging", "prod"], var.environment)
      error_message = "Environment must be one of: dev, staging, prod."
    }
  }
  ```
  (`infra/terraform/modules/hetzner-vps/variables.tf:10-17`)
- Port-range and enum validations follow the same pattern (`additional_tcp_ports`, `server_location` in the same file)
- Commented-out validation blocks are left in place with an explanatory comment when a constraint was found impractical (see `server_enable_ipv4` in `infra/terraform/modules/hetzner-vps/variables.tf:71-74`) — follow this pattern (leave a documented rationale) rather than silently deleting an attempted validation.

**Terraform lifecycle:**
- `lifecycle { ignore_changes = [...] }` is used to prevent drift on fields managed outside Terraform (e.g. `user_data`, `ssh_keys` in `hcloud_server.main`)

## Error Handling

**Bash scripts:**
- `set -euo pipefail` at the top of every script enforces fail-fast behavior
- Required environment variables/config are validated explicitly with a clear error and remediation steps before proceeding, e.g.:
  ```bash
  if [[ -z "$CLAUDE_SETUP_TOKEN" ]]; then
      echo "Error: CLAUDE_SETUP_TOKEN not set"
      echo "Generate a setup token and export it:"
      ...
      exit 1
  fi
  ```
  (`scripts/setup-auth.sh:40-50`)
- Fallback logic prefers explicit failure with actionable instructions over silent defaults (e.g. falling back to `terraform output -raw server_ip`, and erroring with usage instructions if that also fails — `scripts/setup-auth.sh:56-70`)
- Remote commands executed over SSH use `set -euo pipefail` inside the heredoc as well (`scripts/setup-auth.sh:86`)

**Terraform:**
- Errors are surfaced via `validation` blocks with explicit `error_message` text (never left to raw provider errors when a constraint can be checked ahead of apply)

## Comments

- Module/file-level comments explain *what* the file provisions and *why*, placed at the top of the file (see the header in `infra/terraform/modules/hetzner-vps/main.tf:1-7`)
- Inline comments explain non-obvious backend/state caveats directly above the relevant block (see the `backend "s3"` comment block in `infra/terraform/envs/prod/main.tf:16-27` explaining why `key` cannot use `var.project_name`)
- No JSDoc/TSDoc equivalent; HCL `description` fields on variables/outputs serve as the primary inline documentation mechanism

## Module Design

**Terraform modules:**
- Single-purpose modules (currently one: `hetzner-vps`) exposing a clear `variables.tf` (inputs) / `outputs.tf` (exports) contract
- Environments (`envs/prod`) consume modules via relative `source = "../../modules/<name>"` and pass through all module variables explicitly by name rather than using `*` splats
- Cloud-init user data is generated via `templatefile()` from a `.tpl` file rather than inlined in the module (`infra/terraform/envs/prod/main.tf:77-83`, `infra/cloud-init/user-data.yml.tpl`)

**Shell scripts:**
- Common logic (SSH options) factored into a shared include file (`deploy/ssh-opts.inc.sh`) sourced by multiple scripts rather than duplicated
- Scripts accept an optional positional argument (e.g. VPS IP) with a fallback to deriving the value from `terraform output`, keeping scripts usable standalone or as part of the Makefile workflow

## Orchestration Layer

- `Makefile` at repo root is the primary developer interface — wraps `terraform fmt`, `terraform validate`, `init/plan/apply/destroy`, SSH/tunnel helpers, and deploy scripts under a single `make <target>` surface with `## comment` help text per target (used to generate `make help` output)
- When adding new operational tasks, add a new Makefile target with a `## Description` comment rather than expecting direct script invocation only

---

*Convention analysis: 2026-08-21*
</content>
