# External Integrations

**Analysis Date:** 2026-08-21

## APIs & External Services

**Cloud Infrastructure:**
- Hetzner Cloud API - provisions the VPS, SSH key lookup, and firewall
  - SDK/Client: Terraform provider `hetznercloud/hcloud` `~> 1.45` (`infra/terraform/modules/hetzner-vps/main.tf`, `infra/terraform/envs/prod/main.tf`)
  - Auth: `HCLOUD_TOKEN` / `TF_VAR_hcloud_token` (`config/inputs.example.sh`)

**AI / LLM:**
- Anthropic API (Claude) - powers the OpenClaw application running in Docker on the VPS
  - Auth: `ANTHROPIC_API_KEY` (`secrets/openclaw.env.example`) as pay-per-use alternative, OR
  - Claude subscription (Max/Pro) via setup-token flow: `CLAUDE_SETUP_TOKEN` generated locally with `claude setup-token`, pushed to the VPS by `scripts/setup-auth.sh` into `~/.openclaw/agents/main/agent/auth-profiles.json` (JSON profile with `type: "token"`, `provider: "anthropic"`)

**Messaging:**
- Telegram Bot API - primary interface to the OpenClaw agent
  - Auth: `TELEGRAM_BOT_TOKEN` (`secrets/openclaw.env.example`), created via Telegram `@BotFather` `/newbot`

**Search:**
- Brave Search API (optional) - `BRAVE_API_KEY` (`secrets/openclaw.env.example`), free tier at brave.com/search/api

**Source Control / CI:**
- GitHub - used two ways:
  - GitHub Container Registry (GHCR) for pulling private Docker images (`GHCR_USERNAME` / `GHCR_TOKEN`, PAT with `read:packages` scope) - `deploy/bootstrap.sh` runs `docker login ghcr.io`
  - GitHub API (optional, for the OpenClaw "github" skill) - `GH_TOKEN` (PAT scopes: `repo`, `workflow`, `read:org`)

**VPN:**
- Tailscale - optional private networking / SSH-over-WireGuard
  - Installed via `curl -fsSL https://tailscale.com/install.sh | sh` in cloud-init (`infra/cloud-init/user-data.yml.tpl`)
  - Auth: `TF_VAR_tailscale_auth_key` (optional, reusable + pre-authorized key recommended) or manual `tailscale up`
  - Node registers with hostname `openclaw-prod` (MagicDNS)

## Data Storage

**Databases:**
- None (no application database managed by this repo)

**File Storage:**
- Local filesystem on the VPS: `~/.openclaw` (app data/config, mounted into containers), `~/backups` (tar.gz backups), `~/openclaw` (compose files/deploy artifacts)
- Hetzner Object Storage (S3-compatible) — used exclusively as the Terraform remote state backend (not application data)
  - Bucket: `coter-tf-state` (configurable via `TF_VAR_project_name` / `S3_BUCKET`)
  - Endpoint: e.g. `https://hel1.your-objectstorage.com` (`infra/terraform/envs/prod/main.tf`)
  - Auth: `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (mapped from `S3_ACCESS_KEY`/`S3_SECRET_KEY` in `config/inputs.example.sh`)

**Caching:**
- None

## Authentication & Identity

**Auth Provider:**
- Custom / token-based per integration — no centralized identity provider
  - SSH key-based auth for VPS access (fingerprint-based lookup of an existing Hetzner SSH key, `infra/terraform/modules/hetzner-vps/main.tf`)
  - `OPENCLAW_GATEWAY_TOKEN` (generated via `openssl rand -hex 32`) secures the OpenClaw gateway service (`OPENCLAW_GATEWAY_PORT=18789`, `OPENCLAW_GATEWAY_BIND=0.0.0.0` in `secrets/openclaw.env.example`)

## Monitoring & Observability

**Error Tracking:**
- None (no Sentry/error-tracking service configured)

**Logs:**
- Docker JSON file logging (`/etc/docker/daemon.json` sets `max-size: 10m`, `max-file: 3`), written by cloud-init
- Retrieved via `deploy/logs.sh` (`docker compose logs -f --tail 100` over SSH) and `deploy/status.sh` (`docker compose logs --tail=10`)

## CI/CD & Deployment

**Hosting:**
- Hetzner Cloud (single VPS, `server_type` default `cx23`, `server_location` default `nbg1`)

**CI Pipeline:**
- `.github/` directory present but not deeply inspected here; deployment itself is manual/scripted (`make apply`, `make bootstrap`, `make deploy`), not driven by an in-repo CI pipeline for infra changes.

**Deployment Mechanism:**
- Terraform (`make init/plan/apply/destroy`) provisions/destroys the VPS
- `deploy/bootstrap.sh` — one-time setup: GHCR login, copies `docker-compose.yml` from external `openclaw-config` repo, pushes secrets/config, installs backup systemd timer
- `deploy/deploy.sh` — pulls latest images and runs `docker compose up -d` on the VPS
- `deploy/backup.sh` — tar.gz backup of `~/.openclaw`, 7-day retention, runs via systemd timer or manually
- `deploy/restore.sh` — restores from a backup archive, stops/starts compose stack
- `deploy/status.sh`, `deploy/logs.sh` — read-only inspection over SSH
- `scripts/push-config.sh`, `scripts/push-env.sh` — sync local config/secrets to the VPS
- `scripts/setup-auth.sh` — pushes Claude subscription setup-token to the VPS and restarts the container

## Environment Configuration

**Required env vars (local, `config/inputs.sh`):**
- `HCLOUD_TOKEN` / `TF_VAR_hcloud_token`
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (Hetzner Object Storage / S3 backend)
- `TF_VAR_ssh_allowed_cidrs`, `TF_VAR_ssh_key_fingerprint`
- `CONFIG_DIR` (path to sibling `openclaw-config` repo)
- `GHCR_USERNAME`, `GHCR_TOKEN`
- Optional: `TF_VAR_additional_tcp_ports`, `SSH_KEY`, `SERVER_IP`, `CLAUDE_SETUP_TOKEN`, `TF_VAR_enable_tailscale`, `TF_VAR_tailscale_auth_key`, `TF_VAR_server_type`, `TF_VAR_server_location`, `TF_VAR_server_enable_ipv4`

**Required env vars (VPS-side app secrets, `secrets/openclaw.env`):**
- `TELEGRAM_BOT_TOKEN`, `OPENCLAW_GATEWAY_TOKEN`, `GHCR_USERNAME`
- Optional: `ANTHROPIC_API_KEY`, `GH_TOKEN`, `BRAVE_API_KEY`, `GIT_WORKSPACE_REPO`/`GIT_WORKSPACE_TOKEN`/`GIT_WORKSPACE_REMOTE`/`GIT_WORKSPACE_BRANCH`/`GIT_WORKSPACE_SYNC_SCHEDULE`, `OPENCLAW_GATEWAY_PORT`, `OPENCLAW_GATEWAY_BIND`, `OPENCLAW_CONFIG_DIR`, `OPENCLAW_WORKSPACE_DIR`

**Secrets location:**
- `config/inputs.sh` (gitignored) - infra/deploy-time secrets, sourced into the shell
- `secrets/openclaw.env` (gitignored) - application secrets, pushed to VPS via `scripts/push-env.sh`
- VPS-side: `~/.openclaw/agents/main/agent/auth-profiles.json` (Claude subscription token, `chmod 600`)
- No secrets manager / vault integration (e.g. Vault, AWS Secrets Manager) is used — plain env files and gitignore are the only mechanism

## Webhooks & Callbacks

**Incoming:**
- Telegram Bot API webhooks/long-polling into the OpenClaw gateway (`OPENCLAW_GATEWAY_PORT=18789`, exposed via `additional_tcp_ports` if needed, e.g. Microsoft Teams bot callbacks example port `3978` mentioned in `config/inputs.example.sh` comments)
- Optional Microsoft Teams bot callback port noted as an example in firewall config comments (not enabled by default)

**Outgoing:**
- Calls from the OpenClaw application (running in Docker, outside this repo's scope) to Anthropic API, Telegram Bot API, GitHub API, Brave Search API, and optional git remotes for workspace sync (`GIT_WORKSPACE_REPO`/`GIT_WORKSPACE_REMOTE`)

---

*Integration audit: 2026-08-21*
