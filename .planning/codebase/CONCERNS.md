# Codebase Concerns

**Analysis Date:** 2026-08-21

## Tech Debt

**SSH_OPTS array/scalar clobbering across all deploy scripts:**
- Issue: `deploy/ssh-opts.inc.sh` defines `SSH_OPTS` as a bash **array** (`SSH_OPTS=( -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 )`, plus `-o IdentitiesOnly=yes -i "$SSH_IDENTITY_FILE"` when `SSH_IDENTITY_FILE` is set). Every caller sources this file and then immediately **overwrites** `SSH_OPTS` as a plain scalar string: `SSH_OPTS="-o StrictHostKeyChecking=accept-new"` followed by `SSH_OPTS+=" -i $SSH_KEY"`. The scripts then invoke `ssh "${SSH_OPTS[@]}" ...` — array-style expansion on a variable that is now a scalar. This passes `-o StrictHostKeyChecking=accept-new -i /path/to/key` as a **single argv token** to `ssh`/`scp` instead of separate flags, which is invalid `ssh` invocation syntax and can silently fail to apply intended options (or error out) depending on the OpenSSH client's tolerant parsing.
- Files: `deploy/ssh-opts.inc.sh`, `deploy/deploy.sh:23-24`, `deploy/bootstrap.sh:34-35`, `deploy/restore.sh:23-24`, `deploy/status.sh:25-26`, `deploy/logs.sh:20-21`, `scripts/push-env.sh:23-24`, `scripts/push-config.sh:23-24`, `scripts/setup-auth.sh:30-31`
- Impact: `BatchMode`, `ConnectTimeout`, and `IdentitiesOnly`/`SSH_IDENTITY_FILE` support from `ssh-opts.inc.sh` are silently discarded by every script that sources it — only the locally-redefined `-o StrictHostKeyChecking=accept-new` (and optional `-i $SSH_KEY`) actually take effect, and even that may not parse correctly as a single combined argv token. `SSH_IDENTITY_FILE` is referenced only in `ssh-opts.inc.sh`; every other script reads `SSH_KEY` instead — the two env var names are inconsistent and the pathway from `ssh-opts.inc.sh` is dead code in practice.
- Fix approach: Declare `SSH_OPTS` as an array everywhere (`SSH_OPTS=(-o StrictHostKeyChecking=accept-new)`; `[[ -n "${SSH_KEY:-}" ]] && SSH_OPTS+=(-i "$SSH_KEY")`), and either delete the redundant sourcing of `ssh-opts.inc.sh` or reconcile the two option sets (and the `SSH_KEY` vs `SSH_IDENTITY_FILE` naming) into one source of truth.

**`deploy/ssh-opts.inc.sh` is marked as externally-managed but committed to the repo:**
- Issue: The file's header comment reads `# Replaced by deployer: align with MakeService.ssh (CI/Docker; avoids accept-new / agent key mismatch).` — implying an external deployment tool overwrites this file at deploy time, yet it is a tracked, hand-editable file in the repo and (per the bug above) its contents are immediately discarded by every caller anyway.
- Files: `deploy/ssh-opts.inc.sh`
- Impact: Ambiguous ownership — unclear whether local edits to this file persist through the actual deploy pipeline, or whether the checked-in version already reflects a state written by tooling outside this repo. Confusing for future contributors and a likely source of "works on my machine" drift.
- Fix approach: Document the external deployer relationship explicitly in a comment/README, or bring the substitution logic fully into this repo (env-var driven) and drop the ambiguous header.

**Single production environment, no staging/dev parity:**
- Issue: Only `infra/terraform/envs/prod/` exists; there is no `envs/staging` or `envs/dev` to validate infrastructure changes before they hit the production Hetzner VPS.
- Files: `infra/terraform/envs/prod/`
- Impact: Any `terraform apply` change (server_type, firewall rules, cloud-init) is tested directly against production. `hcloud_server` changes to `image`/`server_type`/`location` force a full server replacement (destroys and recreates via Hetzner).
- Fix approach: Add a low-cost `envs/staging` environment sharing the `modules/hetzner-vps` module, or at minimum require `terraform plan` review + manual confirmation gates (already partially covered by `make plan`/`make apply` prompts) before any prod apply.

**`lifecycle.ignore_changes` on `user_data` and `ssh_keys` freezes drift silently:**
- Issue: `hcloud_server.main` has `lifecycle { ignore_changes = [user_data, ssh_keys] }`.
- Files: `infra/terraform/modules/hetzner-vps/main.tf:91-96`
- Impact: Once a server is provisioned, updating `cloud-init/user-data.yml.tpl` (e.g., changing firewall rules baked into `ufw`, rotating the SSH key fingerprint, or enabling Tailscale) has **no effect** on the running server via `terraform apply` — Terraform will not even show a diff for those fields. Operators must know to manually re-run relevant cloud-init steps over SSH or taint/recreate the server. This is not documented anywhere near the resource.
- Fix approach: Add a comment directly above `lifecycle{}` explaining the implication, and/or provide a `make recreate-server` / `taint` helper target with a warning prompt.

## Known Bugs

**None reproduced beyond the SSH_OPTS clobbering bug above** — no other functional bugs were identified through static review; this repo has no runnable test suite for the shell scripts (see Test Coverage Gaps) so behavioral bugs are only caught by shellcheck (`\.github/workflows/shellcheck.yml`) and manual production use.

## Security Considerations

**Passwordless sudo for the application user via cloud-init:**
- Risk: `runcmd` in the cloud-init template grants `${app_user} ALL=(ALL) NOPASSWD:ALL` unconditionally.
- Files: `infra/cloud-init/user-data.yml.tpl:44-46`
- Current mitigation: SSH access to that user is restricted by `ssh_allowed_cidrs` firewall rule and key-only auth (Hetzner default images disable password SSH).
- Recommendations: If the app user's shell is only used for Docker/systemd management, scope sudo to just the needed commands (`systemctl --user`, `docker`, etc.) via a sudoers command allowlist rather than blanket `NOPASSWD:ALL`. At minimum, document why full sudo is needed (e.g., it isn't — the user is already in the `docker` group and manages `systemctl --user` timers without sudo).

**Secrets pass through Hetzner `user_data` (cloud-init) in plaintext:**
- Risk: `tailscale_auth_key` is marked `sensitive = true` in Terraform variables, but it is interpolated directly into `cloud_init_user_data` (a `templatefile()` call) and stored as plaintext in the Hetzner Cloud server's `user_data` field, and in Terraform state.
- Files: `infra/terraform/envs/prod/main.tf:77-83`, `infra/terraform/modules/hetzner-vps/main.tf:78`, `infra/cloud-init/user-data.yml.tpl:73-86`
- Current mitigation: `sensitive = true` prevents the value from being echoed in `terraform plan`/`apply` console output; the S3-compatible remote state backend (Hetzner Object Storage) is assumed to be private.
- Recommendations: Confirm the remote state bucket has strict access controls (state is not encrypted by Terraform itself for S3-compatible backends unless SSE is configured server-side — not visible in `backend.tf`). Consider provisioning Tailscale via a runtime secrets fetch (e.g., pulled over SSH post-boot from `secrets/openclaw.env` push flow) rather than baking the auth key into `user_data`, since `user_data` is retrievable via the Hetzner Cloud API/console by anyone with API token access.

**Firewall opens `additional_tcp_ports` to `0.0.0.0/0` and `::/0` unconditionally:**
- Risk: Any port added to `var.additional_tcp_ports` is exposed to the entire internet (both IPv4 and IPv6), with no CIDR restriction option — unlike SSH (`ssh_allowed_cidrs`) which supports allowlisting.
- Files: `infra/terraform/modules/hetzner-vps/main.tf:44-53`, `infra/terraform/envs/prod/variables.tf:34-43`
- Current mitigation: Ports must be explicitly opted into via `additional_tcp_ports`; port 22 is excluded via the variable's `validation` block.
- Recommendations: If any of these ports are meant for restricted access (e.g., an admin UI), add a parallel `additional_tcp_ports_cidrs` map so each port can be scoped, rather than defaulting to public exposure.

**`GHCR_TOKEN` and `CLAUDE_SETUP_TOKEN` interpolated into remote heredoc shell commands:**
- Risk: `deploy/bootstrap.sh:119-120` builds `echo '$GHCR_TOKEN' | docker login ...` via string interpolation into an SSH command, and `scripts/setup-auth.sh` interpolates `$CLAUDE_SETUP_TOKEN` directly into a heredoc written to a remote file. If either token contains a single quote, this breaks or could allow shell-injection from a maliciously crafted token value (unlikely attack surface since tokens come from the operator's own environment, not user input, but the pattern is fragile).
- Files: `deploy/bootstrap.sh:117-121`, `scripts/setup-auth.sh:78-104`
- Current mitigation: None — relies on tokens being well-formed (no embedded quotes/backticks).
- Recommendations: Pass secrets via SSH `stdin` or a temp env var read for the remote command rather than inline string interpolation, to avoid quoting hazards.

## Performance Bottlenecks

**Single VPS, single point of failure, no autoscaling:**
- Problem: The entire OpenClaw deployment (`hcloud_server.main`) is a single `cx23` Hetzner instance with no load balancer, no replica, no autoscaling group.
- Files: `infra/terraform/modules/hetzner-vps/main.tf:71-97`, `infra/terraform/envs/prod/variables.tf:59-63`
- Cause: By design — this is a small-scale, single-tenant deployment for a Telegram/Claude gateway bot, not a horizontally-scaled service.
- Improvement path: Not applicable at current scale; note if traffic/agent-workload grows beyond one VPS's capacity, `server_type` can be resized (forces replacement) or the module could be extended to a load-balanced multi-server pattern.

## Fragile Areas

**`deploy.sh`'s workspace-directory auto-detection via regex on `docker-compose.yml`:**
- Files: `deploy/deploy.sh:85-92`
- Why fragile: Uses a `grep -oP` PCRE lookbehind/lookahead against a hardcoded default path fragment (`\$\{OPENCLAW_WORKSPACE_DIR:-/home/openclaw/.openclaw/workspace\}/\w+(?=:)`) to discover per-agent workspace subdirectories from `docker-compose.yml`. If the compose file's bind-mount syntax, default value, or variable name changes (e.g., in the separate `openclaw-config` repo this project depends on via `CONFIG_DIR`), this silently matches nothing and workspace directories won't be pre-created, causing the documented root-ownership/EACCES failure mode the code is explicitly trying to avoid.
- Safe modification: Any change to the compose file's workspace mount pattern in the external config repo must be mirrored here; there's no test verifying the regex still matches.
- Test coverage: None.

**Cross-repo dependency on external `openclaw-config` repo (`CONFIG_DIR`):**
- Files: `deploy/bootstrap.sh:23-57`, `scripts/push-config.sh`, `README.md` references
- Why fragile: This repo's bootstrap/push-config flows assume a sibling repository (`openclaw-config`) with a specific internal layout (`docker/docker-compose.yml`, `config/*`). There is no version pinning, compatibility check, or schema validation between the two repos — a breaking layout change in `openclaw-config` silently breaks `make bootstrap`/`make push-config` here with only a generic "not found" error.
- Safe modification: Treat `CONFIG_DIR`'s expected layout as a contract; consider adding a lightweight version/manifest check.
- Test coverage: None — `.github/workflows/` only runs `shellcheck.yml` and `terraform.yml` (fmt/validate), no integration test against a mock `CONFIG_DIR`.

## Scaling Limits

**Local-only backups, 7-day retention, no offsite copy:**
- Current capacity: `deploy/backup.sh` tars `~/.openclaw` to `~/backups` on the same VPS, pruning anything older than 7 days (`RETENTION_DAYS=7`), run via a systemd user timer daily at 3 AM.
- Limit: Because backups live on the same disk/server they protect, a full VPS loss (disk failure, accidental `terraform destroy`, Hetzner incident) destroys both the live data and all backups simultaneously. There is no S3/Object-Storage upload step in `backup.sh` despite the project already provisioning Hetzner Object Storage credentials for Terraform remote state.
- Scaling path: Extend `deploy/backup.sh` to push the tarball to the same (or a separate) Hetzner Object Storage bucket after local creation, and/or `deploy/restore.sh` to pull from remote storage.

## Dependencies at Risk

**Terraform provider pinned to a narrow version range with the Hetzner provider still pre-2.0:**
- Risk: `required_providers.hcloud` is constrained to `~> 1.45` (root module) / `~> 1.45` (child module), lock file resolves to `1.60.1`. The `hetznercloud/hcloud` provider has not yet reached a stable 2.x per this pin; breaking changes across 1.x minors are possible per Hetzner's changelog practices.
- Impact: Automatic `terraform init -upgrade` within the `~>1.45` band could pull in behavior changes without a corresponding `sad.md`/plan review, since there's no CI step pinning to the exact lockfile version beyond `terraform validate`.
- Migration plan: Periodically review `.terraform.lock.hcl` diffs in PRs (the `terraform.yml` CI workflow should already fail formatting/validation issues); consider tightening to an exact provider version in CI to force intentional upgrades.

## Missing Critical Features

**No automated integration/smoke test after `terraform apply` or `make deploy`:**
- Problem: `deploy/status.sh` exists for manual post-deploy inspection, but nothing in CI or the `Makefile` automatically verifies a fresh `apply` + `bootstrap` + `deploy` sequence produces a working container (e.g., a health-check curl against the gateway).
- Blocks: Confidence that infra changes (firewall rule edits, cloud-init changes) don't silently break the deployed service until a human runs `make status` manually.

**No secret rotation tooling:**
- Problem: `hcloud_token`, `TELEGRAM_BOT_TOKEN`, `OPENCLAW_GATEWAY_TOKEN`, `GHCR_TOKEN`, `CLAUDE_SETUP_TOKEN`, and `tailscale_auth_key` are all long-lived manual secrets set via `config/inputs.sh` / `secrets/openclaw.env` with no expiry/rotation reminders or scripted rotation flow.
- Blocks: Routine credential hygiene; a leaked token (e.g., via shell history, since several scripts pass secrets as CLI args/interpolated strings — see Security Considerations) has an unbounded window of validity.

## Test Coverage Gaps

**No test suite for deploy/scripts shell scripts beyond shellcheck linting:**
- What's not tested: `deploy/*.sh` and `scripts/*.sh` (bootstrap, deploy, backup, restore, status, logs, push-env, push-config, setup-auth) have zero unit/integration tests. Correctness is only checked by static `shellcheck.yml` (syntax/style) and the `terraform.yml` workflow's `terraform fmt -check`/`terraform validate` (no `plan`/`apply` against a real or mocked Hetzner account).
- Files: `.github/workflows/shellcheck.yml`, `.github/workflows/terraform.yml`, all of `deploy/`, `scripts/`
- Risk: Bugs like the `SSH_OPTS` array/scalar clobbering above pass shellcheck (it's syntactically valid bash) and terraform validate (unrelated) undetected; they only surface at real deploy time against production.
- Priority: Medium — given this is solo/small-team infra tooling rather than a multi-contributor app, the highest-value addition would be a `shellcheck` + `bash -n` + a lightweight `bats`/`shunit2` test for the SSH option-building logic specifically, since that's shared across every script.

---

*Concerns audit: 2026-08-21*
