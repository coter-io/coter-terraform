# Testing Patterns

**Analysis Date:** 2026-08-21

## Test Framework

**No unit/integration test runner is present.** This repository is Terraform infrastructure-as-code plus operator Bash scripts; there is no application code, so there is no Jest/Vitest/pytest-style test suite and no `*.test.*` / `*.spec.*` files exist anywhere in the repo.

Verification instead relies on:
- Static validation (`terraform validate`, `terraform fmt -check`)
- Shell linting (`ShellCheck`)
- Manual/operational verification via `status.sh`, `logs.sh`, and SSH-based checks

**Run Commands:**
```bash
make fmt        # terraform fmt -recursive infra/
make validate   # terraform init -backend=false + terraform validate (in envs/prod)
```

## CI Verification Pipeline

Two GitHub Actions workflows substitute for a test suite:

**`.github/workflows/terraform.yml` ("Terraform CI"):**
- `terraform-format`: runs `terraform fmt -check -recursive infra/terraform/` on every PR/push to `main`
- `terraform-validate`: matrix over environments (currently `[prod]`); runs `terraform init -backend=false` then `terraform validate` inside `infra/terraform/envs/<environment>`
- `module-validate`: validates the `hetzner-vps` module in isolation

**`.github/workflows/shellcheck.yml` ("ShellCheck"):**
- Runs `ludeeus/action-shellcheck` against `./deploy` and `./scripts` directories with `severity: warning`
- Lints every `.sh` file under those two directories; no explicit test execution, purely static analysis

When adding new Terraform code, ensure it passes `terraform fmt` and `terraform validate` locally before pushing — these are hard CI gates. When adding new shell scripts under `scripts/` or `deploy/`, ensure they are ShellCheck-clean (warnings will surface in CI, though the workflow does not appear to fail the build on warnings — verify severity threshold in `.github/workflows/shellcheck.yml` if stricter enforcement is needed).

## Manual Verification Patterns

Because there's no automated test suite, the repo relies on operator scripts to verify state after `terraform apply` or deploys:

- `deploy/status.sh` — checks running state of the deployed service on the VPS
- `deploy/logs.sh` — tails/fetches logs from the VPS for manual inspection
- `make validate` — the closest equivalent to a "test" for Terraform changes (syntax/schema validation only, no plan execution against real infra)

**Recommended verification flow for infrastructure changes:**
1. `terraform fmt -recursive infra/` (or `make fmt`)
2. `make validate`
3. `terraform plan` (via `make plan`) reviewed manually for expected diff
4. `terraform apply` (via `make apply`)
5. `deploy/status.sh` / `deploy/logs.sh` to confirm the VPS/service is healthy post-apply

## Test Types

**Unit Tests:** Not applicable — no application code exists to unit test.

**Integration Tests:** Not present. `terraform validate` checks HCL syntax/internal consistency only; it does not verify against live Hetzner Cloud API or produce a plan.

**E2E Tests:** Not used. Real infrastructure changes are verified manually via `terraform plan`/`apply` and post-deploy status checks.

## Coverage

**Requirements:** None enforced — no coverage tooling applicable to this repo type.

## Gaps

- No automated `terraform plan` dry-run gate in CI beyond `validate` (plan requires cloud credentials and is not run against a sandbox account)
- No test coverage for the Bash deployment scripts beyond static linting (ShellCheck does not execute the scripts)
- No smoke test that exercises the `hetzner-vps` module's actual apply/destroy cycle in CI (would require ephemeral cloud credentials and cost)

---

*Testing analysis: 2026-08-21*
</content>
