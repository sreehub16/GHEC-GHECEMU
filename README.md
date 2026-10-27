# GHEC ➜ GHEC Migration with GitHub Actions (GEI) — Unified Migration Framework

An operational framework for planning, executing, and validating **GitHub Enterprise Cloud (GHEC)** migrations with **GitHub Enterprise Importer (GEI)** and GitHub Actions. The solution provides two independently triggered workflows: **repository-to-repository migration** and **organization-to-organization migration**. It supports standard GitHub.com and GitHub Enterprise Cloud with Data Residency (GHEC-DR) endpoints, subject to the scenario-specific constraints below.

> **Document scope:** This guide describes the supplied `ghec-to-ghec-repo.yaml` and `ghec-to-ghec-org.yml` workflows and the repository scripts referenced by the repository workflow. It does not assert that a customer migration has been successfully completed. Perform a controlled pilot and review its evidence before production rollout.

## 1. Solution at a glance

| Capability | Repository migration workflow | Organization migration workflow |
|---|---|---|
| Entry point | `ghec-to-ghec-repo.yaml` | `ghec-to-ghec-org.yml` |
| Initiation | Manual GitHub Actions dispatch | Manual GitHub Actions dispatch |
| Pre-migration checks | Scenario, credentials, CSV, repository readiness | Scenario, credentials, source organization, target name availability |
| Approval | `migration-approval` before Stage 2 | `migration-approval` before Stage 2 |
| Migration operation | `gh gei migrate-repo` via `scripts/3_migration.sh` | `gh gei migrate-org` |
| Post-migration checks | Repository branches and commit SHAs via script | Organization accessibility and repository inventory/metadata parity |
| Additional configuration transfer | Organization, repository and environment **Actions variables** (Stage 4) | Not implemented in the supplied organization workflow |
| Execution evidence | Job summaries, CSV outputs, migration/validation logs, artifacts | Job summaries, migration logs, JSON and CSV validation artifacts |

**Operating model:** Treat organization and repository migrations as distinct change activities. An organization migration is not a prerequisite enforced by the repository workflow; select the workflow that matches the approved migration plan and target provisioning strategy.

## 2. Supported migration scenarios

### 2.1 Repository-to-repository workflow

| Scenario (exact workflow selection) | Source | Target | Source API configuration | Target API configuration |
|---|---|---|---|---|
| `Non-EMU GHEC -> EMU GHEC-DR` | Standard GitHub.com | GHEC-DR tenant | Default `https://api.github.com` | Tenant DR API |
| `Non-EMU GHEC -> EMU GHEC` | Standard GitHub.com | Standard GitHub.com | Default `https://api.github.com` | Default `https://api.github.com` |
| `EMU GHEC -> EMU GHEC-DR` | Standard GitHub.com | GHEC-DR tenant | Default `https://api.github.com` | Tenant DR API |
| `GHEC-DR -> GHEC-DR` | GHEC-DR tenant | GHEC-DR tenant | Source tenant DR API | Target tenant DR API |

The fourth scenario is present **only in the supplied repository workflow**. A dropdown selection identifies the intended scenario and triggers validation; it does **not** automatically provision endpoints or credentials.

### 2.2 Organization-to-organization workflow

| Scenario (exact workflow selection) | Source | Target |
|---|---|---|
| `Non-EMU GHEC -> EMU GHEC-DR` | Standard GitHub.com | GHEC-DR tenant |
| `Non-EMU GHEC -> EMU GHEC` | Standard GitHub.com | Standard GitHub.com |
| `EMU GHEC -> EMU GHEC-DR` | Standard GitHub.com | GHEC-DR tenant |

**Organization workflow limitation:** The supplied organization workflow always validates its source through `https://api.github.com`. **GHEC-DR-to-GHEC-DR organization migration is not implemented** in this workflow.

## 3. Architecture and execution sequence

### Repository workflow — four stages

```text
Source inventory and target mapping (scripts/repos.csv)
                     |
                     v
Stage 1 — Pre-migration validation and readiness checks
                     |
                     v
           Migration approval gate
                     |
                     v
Stage 2 — Parallel repository migration using GEI
                     |
                     v
Stage 3 — Post-migration branch and commit validation
                     |
                     v
       Stage 4 — GitHub Actions variables migration
                     |
                     v
          Review evidence and obtain sign-off
```

Stage 1, Stage 2, Stage 3 and Stage 4 are independently selectable using workflow inputs, subject to their job dependencies. Stage 2 may run when Stage 1 is **successful or intentionally skipped**. Stage 3 requires a successful Stage 2 **job**; Stage 4 requires a successful Stage 3 **job**. An approval environment also applies to Stage 4.

### Organization workflow — three stages

```text
Stage 1 — Validate scenario, PATs, source organization,
          target organization availability and GEI readiness
                     |
                     v
           Migration approval gate
                     |
                     v
Stage 2 — GEI organization migration (creates target org)
                     |
                     v
Stage 3 — Organization and repository metadata validation
                     |
                     v
          Review evidence and obtain sign-off
```

The organization workflow does not expose per-stage enable/disable toggles. Its post-validation stage runs only after a successful organization migration job.

## 4. Repository layout and ownership

The repository workflow expects the following script paths. Ensure the files exist in the same repository and branch as the workflow before execution.

```text
.github/
└── workflows/
    ├── ghec-to-ghec-repo.yaml
    └── ghec-to-ghec-org.yml

scripts/
├── 1_inventory-report.sh
├── 2_migration-readiness.sh
├── 3_migration.sh
├── 4_post-migration-validation.sh
├── 5_variables-migration.sh
└── repos.csv

README.md
```

The layout above is the **recommended committed layout**. Workflow files were supplied as `ghec-to-ghec-repo.yaml` and `ghec-to-ghec-org.yml`; place them under `.github/workflows/` to make them available in GitHub Actions. The five scripts are referenced by the existing README/workflow, but were **not included in this documentation review**; verify their current implementations before production execution.

| Component | Responsibility |
|---|---|
| `1_inventory-report.sh` | Interactive source inventory preparation; run separately before the workflow |
| `2_migration-readiness.sh` | Checks open PRs, issues, and queued/running workflows; produces readiness output |
| `3_migration.sh` | Executes GEI repository migrations, concurrency and CSV mapping |
| `4_post-migration-validation.sh` | Compares source and target branches and commit SHAs |
| `5_variables-migration.sh` | Transfers supported organization, repository and environment Actions variables |
| `ghec-to-ghec-repo.yaml` | Orchestrates four repository stages and artifact collection |
| `ghec-to-ghec-org.yml` | Orchestrates three organization stages and artifact collection |

## 5. Prerequisites and access governance

Before starting a customer migration, confirm the following:

- **Migration authorization:** An approved change window, source/target ownership, target enterprise and organization design, and a documented rollback/contingency approach.
- **GitHub access:** Appropriate enterprise and organization access for the source and target, plus PAT scopes/permissions required by the chosen GEI migration operation. A successful `GET /user` confirms authentication **only**, not migration authorization.
- **Actions permissions:** Permission to dispatch workflows, configure Actions secrets, and configure the `migration-approval` environment with designated reviewers.
- **Network access:** Runner connectivity to GitHub.com and any required `*.ghe.com` tenant API endpoints, plus any endpoints used by GEI.
- **Tools:** Bash, GitHub CLI (`gh`), GEI extension (`gh gei`), `curl`, `jq`, and Python 3. The workflows install tools on GitHub-hosted runners where specified; preconfigure and test self-hosted runners.
- **Migration preparation:** A complete repository mapping CSV for repository migrations; target enterprise slug and available target organization name for organization migrations.

**Security practice:** Store PATs in GitHub Actions secrets; never commit tokens, print them in logs, or attach them to support tickets. Restrict access to migration artifacts, which may contain repository names, metadata and operational details. Rotate or revoke migration credentials according to your organization's access policy after cutover.

## 6. Secrets and API endpoint configuration

Configure repository or organization Actions secrets in **Settings → Secrets and variables → Actions** (subject to your organization's secret access policy).

| Secret | Repository workflow | Organization workflow | Required when |
|---|---|---|---|
| `SOURCE_PAT` | Yes | Yes | All scenarios |
| `TARGET_PAT` | Yes | Yes | All scenarios |
| `SOURCE_API_URL` | Yes, with GitHub.com default | No; source fixed to GitHub.com | Repository **DR → DR** scenario |
| `TARGET_API_URL` | Yes, with GitHub.com default | Yes, for DR target scenarios | Any GHEC-DR target |

**Important:** The supplied workflows read **`secrets.SOURCE_PAT`**, **`secrets.TARGET_PAT`**, **`secrets.SOURCE_API_URL`** and **`secrets.TARGET_API_URL`** as applicable. Do **not** substitute `GH_SOURCE_PAT` / `GH_TARGET_PAT` as Actions secret names unless you also deliberately change the workflow. GEI itself uses `GH_SOURCE_PAT` and `GH_PAT` in its CLI environment; the migration script is responsible for mapping the configured PATs.

| Endpoint type | API URL example | CLI behavior |
|---|---|---|
| Standard GHEC | `https://api.github.com` | Omit optional DR-specific API flags |
| GHEC-DR | `https://api.tenant.ghe.com` | Supply `--target-api-url` for DR target; `--github-source-api-url` only for DR source |

For standard GitHub.com sources, **do not pass** `--github-source-api-url https://api.github.com`. GEI v1.34.0 treats `--github-source-api-url` as a **Data Residency source-only** option and rejects a GitHub.com URL. Where the repository migration script supports both source types, its source API flag must be conditional. GEI also reads `GH_SOURCE_API_URL` when the flag is absent; clear any inherited DR source setting for standard GitHub.com migrations. The supplied workflow YAML alone does not establish that the referenced shell script implements this safeguard.

### Authentication verification

A basic source token authentication check (run only in a secure shell with `SOURCE_PAT` already populated):

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer ${SOURCE_PAT}" \
  https://api.github.com/user
```

`200` means the token authenticated to this endpoint. It does **not** prove that the token can export a source repository or that GEI will route archive requests to the correct endpoint.

## 7. Repository migration: operator runbook

### Step 1 — Inventory and mapping

Generate inventory separately, where the script is available:

```bash
./scripts/1_inventory-report.sh
```

Prepare and commit `scripts/repos.csv` with the approved target mappings. The documented migration format is:

```csv
source_org,source_repo,repo_url,repo_size_MB,target_org,target_repo,target_repo_visibility
source-org,repo-1,https://github.com/source-org/repo-1,10.25,target-org,repo-1,private
```

| Column | Purpose |
|---|---|
| `source_org`, `source_repo` | Source repository identity |
| `target_org`, `target_repo` | Destination mapping |
| `target_repo_visibility` | Requested target visibility, e.g. `private` |
| `repo_url`, `repo_size_MB` | Inventory metadata; not target routing parameters |

Verify that each mapping is authorized, the destination names are suitable, and the target organization exists or is provisioned according to the migration plan.

### Step 2 — Configure the approval gate

Create the GitHub Actions environment **`migration-approval`** under **Settings → Environments**, assign required reviewers, and apply the organization's deployment protection policy. Both migration workflows use this environment before Stage 2; the repository workflow also uses it before Stage 4.

### Step 3 — Run the repository workflow

Open **Actions → `ghec-to-ghec-repo-migration-framework` → Run workflow** and supply:

| Input | Default | Operator guidance |
|---|---|---|
| `migration_scenario` | No default shown | Select the exact source/target topology |
| `runner` | `ubuntu-latest` | Use a prevalidated runner; for self-hosted supply a JSON label array |
| `csv_path` | `scripts/repos.csv` | Path checked by Stage 1; see important limitation below |
| `max_concurrent` | `10` | Choose 1 for a pilot; raise only after observing capacity and results |
| `run_pre_validation` | `true` | Normally leave enabled |
| `run_migration` | `true` | Controls GEI migration execution |
| `run_post_validation` | `true` | Normally leave enabled |
| `run_vars_migration` | `true` | Enable only when variable migration is approved and applicable |

Example self-hosted runner selector:

```text
["self-hosted","linux","x64","ghec-to-ghec-migration"]
```

**CSV-path limitation in the supplied workflow:** Stage 1 checks `inputs.csv_path`, but Stage 2 explicitly invokes `3_migration.sh` with `--csv "scripts/repos.csv"`; the pre-validation summary parser also reads that fixed path. For reliable operation **use and commit `scripts/repos.csv`** unless the workflow is separately modified and tested to honor another path end to end.

### Step 4 — Review each stage

| Stage | Execution | Evidence and acceptance focus |
|---|---|---|
| **1 — Readiness** | Validates scenario, PAT authentication, CSV and repository readiness | Review active PRs, running workflows, open issues, and readiness summary |
| **2 — Migration** | Runs `scripts/3_migration.sh` in parallel using GEI | Inspect `repos_with_status.csv`, migration logs and per-repository outcomes |
| **3 — Post-validation** | Runs `scripts/4_post-migration-validation.sh` | Review branch-count comparisons, branch-level SHA mismatches and exceptions |
| **4 — Variables** | Runs `scripts/5_variables-migration.sh` | Confirm supported org/repo/environment variables, visibility and access as applicable |

**Acceptance rule:** A green GitHub Actions job is not a substitute for checking per-repository status and validation artifacts. The workflow invokes a separate shell script whose exact exit-code handling was not included in the supplied references. Sign off only after inspecting evidence for **all** intended repositories and resolving exceptions.

## 8. Organization migration: operator runbook

The organization workflow uses GEI's `migrate-org` operation to create a **new target organization** within the specified target enterprise. It is not a general-purpose synchronization workflow for an existing destination organization.

### Step 1 — Plan the destination

Confirm the target enterprise slug, destination endpoint and **unused** target organization name. The source and target names may be identical **when that name is available on the destination**. The workflow's target check expects a `404` for the destination organization; a `200` causes the workflow to stop. Other unexpected responses also stop execution.

### Step 2 — Start the workflow

Open **Actions → `ghec-to-ghec-org-migration-framework` → Run workflow** and enter:

| Input | Description |
|---|---|
| `migration_scenario` | One of the three supported organization scenarios |
| `source_org` | Existing GitHub.com source organization |
| `target_org` | New destination organization name; may match `source_org` if available |
| `target_enterprise` | Destination enterprise slug |

Configure `SOURCE_PAT` and `TARGET_PAT`; configure `TARGET_API_URL` as an Actions **secret** for a DR target. For the standard GHEC target scenario, the workflow resolves `https://api.github.com` automatically. Unlike the repository workflow, this workflow uses GitHub-hosted `ubuntu-latest` runners and does not expose a runner input.

### Step 3 — Review the three stages

**Stage 1 — Organization validation:** Resolves the destination API; validates both PATs using `/user`; checks source organization access; verifies that the destination organization does not exist; installs GEI and tests target CLI authentication. The workflow does not require different source and target names.

**Stage 2 — Organization migration:** After approval, executes the equivalent of:

```bash
gh gei migrate-org \
  --github-source-org "$SOURCE_ORG" \
  --github-target-org "$TARGET_ORG" \
  --github-target-enterprise "$TARGET_ENTERPRISE" \
  [--target-api-url "$TARGET_API_URL"]
```

The bracketed argument above is **illustrative** and is supplied only for a DR target. The workflow captures the GEI process exit code and fails the job on a nonzero result.

**Stage 3 — Post-migration validation:** Retrieves source and target organization records and paginated repository inventories. It compares repository counts, names, visibility, default branch and archived state. It produces repository-level discrepancy rows and an overall pass/fail result. The GEI-created `gei-migration-results` repository is excluded from target parity comparison. **This is high-level metadata parity validation**, not a full comparison of commits, pull requests, issues, teams, memberships, secrets or branch protection rules.

## 9. Outputs, artifacts and audit evidence

| Workflow/stage | Principal files | Artifact naming pattern |
|---|---|---|
| Repository — Stage 1 | `precheck.log`, `scripts/repos.csv` | `stage1-precheck-<run_id>` |
| Repository — Stage 2 | `migration.log`, `repos_with_status.csv`, `migration-*.txt`, `octoshift-logs.tgz` | `stage2-migration-<run_id>` |
| Repository — Stage 3 | `post_validation.log`, `validation-log-*.txt`, `validation-*.json` | `stage3-postvalidation-<run_id>` |
| Repository — Stage 4 | `vars_migration.log`, `repos_with_status.csv` | `stage4-vars-migration-<run_id>` |
| Organization — Stage 2 | `org_migration.log`, matching Octoshift logs | `ghec-to-ghec-org-migration-<run_id>` |
| Organization — Stage 3 | `source-org.json`, `target-org.json`, `source-repositories.json`, `target-repositories.json`, `repository-validation.csv`, `org-post-migration-validation.json` | `ghec-to-ghec-org-post-validation-<run_id>` |

Artifacts are uploaded using `if: always()` for the configured upload steps, including some failure paths; an artifact's presence does not imply success. GitHub Actions job summaries provide quick operational visibility, while the underlying CSV/JSON/log files support detailed review.

### Recommended customer acceptance record

Record the change identifier, workflow run URL and run ID, scenario, source and target organization/tenant, start/end times, approvals, inventory totals, successful and failed repository counts, outstanding discrepancies, validation results, artifact locations, and formal customer/operations sign-off. Store evidence according to customer retention and access-control requirements.

## 10. Troubleshooting and recovery guidance

| Symptom | Likely area to investigate | Recommended action |
|---|---|---|
| `SOURCE_PAT` or `TARGET_PAT` missing | Actions secrets | Check exact secret names and repository/environment access policies |
| `/user` returns `401` | Token or endpoint authentication | Check token validity, correct host, authorization and expiry; do not expose token contents |
| `/user` returns `200`, migration still fails | Authorization, routing or GEI behavior | Inspect the failing request URL, GEI logs and required migration permissions; `/user` alone is insufficient |
| `--github-source-api-url must be a valid ... data residency API URL` | Incorrect source flag | Do not supply `https://api.github.com` to the DR-only source flag |
| GitHub.com source archive request goes to target DR API | GEI source/target routing | Check executed arguments, inherited `GH_SOURCE_API_URL`, extension version and logs; do not assume a valid PAT fixes routing |
| DR target is treated as GitHub.com | Missing/wrong `TARGET_API_URL` secret | Verify the selected scenario and destination API value |
| Target organization already exists | Organization name availability | Select an unused destination name or revisit the approved target design; the org workflow does not migrate into an existing org |
| CSV not found or wrong repositories processed | Fixed CSV path in Stage 2 | Ensure the intended mapping is committed at `scripts/repos.csv` |
| Repository migration job green but CSV shows failures | Script status propagation | Inspect `repos_with_status.csv` and GEI logs; treat failed repositories as unresolved regardless of job color |
| Repository post-validation mismatch | Branch or commit differences | Compare source/target branch names and SHAs and document exceptions |
| Organization post-validation mismatch | Repository inventory/metadata | Inspect `repository-validation.csv` and `org-post-migration-validation.json` |
| Variables missing after migration | Scope, permissions or execution | Inspect `vars_migration.log`; separately configure secrets and other unsupported settings |

**Recovery principle:** Stop further production waves when validation fails. Preserve artifacts, assess whether target objects were partially created, determine the safe retry or cleanup path using GEI guidance and the approved change plan, and rerun only after root-cause review. The supplied workflows do **not** implement automatic rollback.

## 11. Scope boundaries and known implementation considerations

The supplied workflows provide automation and evidence, but the following distinctions are material to production planning:

1. **Repository vs. organization coverage:** Repository workflow offers four scenarios; organization workflow offers three. DR-source organization migration is not included.
2. **Source API behavior:** Standard GitHub.com sources must not be passed through GEI's DR-only `--github-source-api-url` option. The referenced `3_migration.sh` implementation must be verified separately because it was not supplied with these workflows.
3. **Organization creation:** `migrate-org` creates a new destination organization; an already-existing destination is rejected by the workflow. Equal source/target names are permitted by input validation, subject to destination availability.
4. **Variable migration:** Repository Stage 4 targets GitHub Actions **variables** at organization, repository and environment levels. It does not claim to migrate Actions **secrets**, environment protection rules or every organization policy.
5. **Validation depth:** Repository post-validation is described by the original README as branch/SHA checks. Organization post-validation performs organization accessibility and repository metadata comparisons, **not** a complete data-integrity audit.
6. **CSV input:** The repository workflow exposes `csv_path`, but Stage 2 uses `scripts/repos.csv` explicitly. Keep this path consistent.
7. **Status propagation:** The repository workflow's success condition depends on the migration script exit code; verify row-level results before declaring completion.
8. **Version and environment:** GEI behavior can change across extension versions. Validate the installed version and pilot the selected scenario; the supplied YAML installs the extension without pinning a specific version.
9. **Source DR organization support:** The organization workflow's source checks and post-validation are hardcoded to `https://api.github.com`; do not use it for a DR source without an independently designed and tested extension.
10. **Operational assurance:** Actual production success, full migration coverage, data parity and rollback capability cannot be inferred from YAML definitions alone.

## 12. Go-live checklist

### Before execution

- [ ] Confirm the approved source/target scenario and target tenant or enterprise.
- [ ] Select the correct repository or organization workflow.
- [ ] Confirm migration eligibility, PAT permissions, SSO/enterprise authorization and runner connectivity.
- [ ] Configure `SOURCE_PAT`, `TARGET_PAT` and required DR API URL secrets.
- [ ] Confirm `migration-approval` environment and required reviewers.
- [ ] For repository migration, generate, review and commit `scripts/repos.csv`.
- [ ] For organization migration, verify target enterprise and target organization name availability.
- [ ] Validate the committed scripts and GEI CLI behavior for the chosen scenario.
- [ ] Run a single-repository or nonproduction pilot and review the full migration evidence.
- [ ] Establish change window, communications, exception handling and recovery plan.

### During execution

- [ ] Capture workflow run ID and approval evidence.
- [ ] Monitor stage status, GEI output and any endpoint/authentication errors.
- [ ] Track repository-level success/failure, not only workflow job status.
- [ ] Escalate failures and pause further waves where required.

### After execution

- [ ] Reconcile migrated repositories against the approved inventory.
- [ ] Review branch/SHA validation for repository migration or metadata parity for organization migration.
- [ ] Verify required Actions variables and manually provision unsupported settings and secrets.
- [ ] Record and resolve discrepancies; obtain customer acceptance.
- [ ] Securely retain artifacts, complete operational handover and rotate/revoke temporary credentials as appropriate.

---

## Document maintenance

**Source of truth:** The committed workflow YAML files and referenced scripts take precedence over this operational guide if implementation changes. Review this README whenever scenario options, secret names, approval gates, script behavior or validation criteria change.

**Distribution:** This document is suitable for customer-facing solution walkthroughs and controlled migration planning; production authorization remains subject to customer-specific security, governance and acceptance processes.
