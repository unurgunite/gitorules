<h1 align="center">gitorules</h1>

<p align="center">
<a href="https://github.com/unurgunite/gitorules/actions"><img src="https://github.com/unurgunite/gitorules/actions/workflows/ci.yml/badge.svg?branch=master" alt="CI"></a>
<a href="https://github.com/unurgunite/gitorules/blob/master/LICENSE"><img src="https://img.shields.io/github/license/unurgunite/gitorules.svg" alt="License"></a>
<a href="https://crystal-lang.org"><img src="https://img.shields.io/badge/crystal-%3E%3D%201.21-blue.svg" alt="Crystal"></a>
</p>

Declarative GitHub Ruleset Manager.

Manage branch protection rules across all your repositories from a single YAML config.

* [Quick start](#quick-start)
* [Installation](#installation)
    * [GitHub Releases](#github-releases)
    * [Build from source](#build-from-source)
* [CLI](#cli)
    * [Commands](#commands)
    * [Options](#options)
    * [Exit codes](#exit-codes)
    * [`gitorules lint`](#gitorules-lint)
    * [`gitorules verify`](#gitorules-verify)
    * [`gitorules migrate`](#gitorules-migrate)
    * [Authentication](#authentication)
* [Configuration: `.gitorules.yml`](#configuration-gitorulesyml)
    * [File structure](#file-structure)
    * [Multi-org mode](#multi-org-mode)
    * [Rule types](#rule-types)
    * [Single-org mode](#single-org-mode)
    * [Branch types](#branch-types)
    * [Branch type options](#branch-type-options)
        * [`pattern`](#pattern)
        * [Merge methods: `merge`, `squash`, `rebase`](#merge-methods-merge-squash-rebase)
        * [`checks`](#checks)
        * [`name`](#name)
    * [What gitorules creates](#what-gitorules-creates)
    * [Config lookup logic](#config-lookup-logic)
    * [`gitorules status` output](#gitorules-status-output)
    * [Labels](#labels)
* [Workflows sync](#workflows-sync)
    * [Template layout](#template-layout)
    * [Allowlist](#allowlist)
    * [Behavior](#behavior)
    * [Token scopes](#token-scopes)
    * [Node and VSCode stacks](#node-and-vscode-stacks)
* [JSON output](#json-output)
* [Development](#development)
* [Contributing](#contributing)
* [License](#license)

## Quick start

```shell
# Check current ruleset state
gitorules status

# Preview pending changes
gitorules diff

# Apply configuration
gitorules apply

# Generate .gitorules.yml from existing rulesets
gitorules init --org myorg

# Validate config without calling the API
gitorules lint

# Convert legacy org/repos/rules to defaults/scopes
gitorules migrate
```

## Installation

### GitHub Releases

Download the latest binary from [releases](https://github.com/unurgunite/gitorules/releases).

### Build from source

```shell
git clone https://github.com/unurgunite/gitorules.git
cd gitorules
shards install
crystal build src/gitorules.cr --release -o gitorules
```

Requires Crystal 1.21+.

## CLI

```shell
gitorules <status|apply|diff|init|lint|migrate|verify> [options]
```

### Commands

| Command   | Description                                       |
|-----------|---------------------------------------------------|
| `status`  | Show ruleset status for repositories              |
| `apply`   | Apply ruleset configuration from `.gitorules.yml` |
| `diff`    | Show pending changes without applying             |
| `init`    | Generate `.gitorules.yml` from existing rulesets  |
| `lint`    | Validate config schema and values (offline)       |
| `verify`  | Verify required checks are produced by workflows (offline) |
| `migrate` | Convert legacy config to `defaults`/`scopes` shape |

### Options

| Flag            | Description                                          |
|-----------------|------------------------------------------------------|
| `--dry-run`     | Preview apply changes without making them            |
| `--diff`        | Show pending changes (same as `diff` command)        |
| `--repo REPO`   | Target a single repository (`owner/name`)            |
| `--scope NAME`  | Only process repositories in this scope             |
| `--only LIST`   | Only process subsystems (`branch,labels,workflows`)  |
| `--exclude REPO`| Exclude repository (repeatable)                      |
| `--org ORG`     | GitHub organization name (for `init`)                |
| `--in-place`    | Overwrite config file in place (`migrate` only)      |
| `--json`        | Machine-readable JSON output                         |
| `--quiet`       | Suppress all output except errors                    |
| `--verbose`     | Show unchanged workflows and detailed output         |
| `--yes`         | Skip confirmation prompt and apply immediately       |
| `--token TOKEN` | GitHub personal access token                         |
| `--config PATH` | Path to config file (default: `.gitorules.yml`)      |
| `--version`     | Show version                                         |
| `-h`, `--help`  | Show help                                            |

**Apply confirmation:**

Before applying changes, `gitorules apply` shows a diff and asks for confirmation. Use `--yes` to skip the prompt in
scripts/automation.

### Exit codes

- **0** — all rulesets are up to date (no changes needed). For `lint`: config is valid (warnings allowed).
  For `verify`: all required checks are produced (warnings allowed).
  For `migrate`: migration succeeded. For `status`/`diff`/`apply`, see below
- **1** — changes detected (in `diff` mode) or changes were applied (in `apply` mode). Also returned when the
  confirmation prompt is declined (changes exist but were skipped)
- **2** — execution error (config error, API error, etc.). For `lint`: schema or value errors found.
  For `verify`: required checks with no producing workflow found.
  For `migrate`: read, parse, or schema error

### `gitorules lint`

Validates `.gitorules.yml` offline (no API calls, no token required).
Every error states what is wrong, where (file and key), and how to fix it.

```shell
gitorules lint --config .gitorules.yml
```

Checks include:

- merge methods must be the string `only` — `merge: true` is an error, not silently ignored
- at most one of `merge`/`squash`/`rebase` may be `only`
- `checks` must be a non-empty list of strings
- check names without a `Workflow / job` separator produce a warning; verify real names with
  `gh api repos/<org>/<repo>/commits/HEAD/check-runs`
- check patterns with glob characters (`*`, `?`, `[`) produce a warning: they match locally
  and are skipped when creating rulesets
- every exact required check must be produced by a workflow in the same scope
  (see [`gitorules verify`](#gitorules-verify)): a stale check such as `check / check`
  is an error shaped as what is wrong (the check name), where
  (`rules.<scope>.<type>.checks`), how to fix (rename the check or update the
  template), plus the list of checks the scope actually produces.
  A produced job with no matching requirement is a warning, not an error

Exit codes: **0** when the file is valid (warnings allowed), **2** on any error.

### `gitorules verify`

Dry-run report of required-vs-produced checks per scope (offline, no API calls,
no token required). Reuses the same cross-check core as `lint` without failing
the schema validation. Accepts both `gitorules verify` and `gitorules scope verify`
spellings.

```shell
gitorules verify --config .gitorules.yml
gitorules scope verify --scope backend --config .gitorules.yml
gitorules verify --json | jq '.[] | {scope, missing, extra, ok}'
```

Matrix axes in templates expand to concrete GitHub check names
(`CI / test (20)`), so comparison is exact, not prefix-based. Both
`matrix: {key: [values]}` maps and `include:` lists are supported;
unknown shapes fall back to the plain job name with a warning.

Exit codes: **0** when every required check is produced (warnings allowed),
**2** on missing checks or read/parse errors.

### `gitorules migrate`

Converts a legacy `org`/`repos`/`rules` (or `orgs`) config to the `defaults`/`scopes` shape:

```shell
# Print migrated YAML to stdout (source file untouched)
gitorules migrate --config .gitorules.yml

# Rewrite the source file
gitorules migrate --config .gitorules.yml --in-place
```

Single-org input moves shared rules to `defaults` and repositories to `scopes.main`
(short names expand to full `org/name` entries; bare `org` without `repos` becomes `org/*`).
Multi-org input becomes one scope per organization. Input already using `scopes`
is returned unchanged.

Exit codes: **0** on success, **2** on read, parse, or schema errors.

### Authentication

Use a Personal Access Token with `repo` and `read:org` scopes:

```shell
gitorules --token ghp_xxx status
```

Or set `GITHUB_TOKEN` environment variable.

If no token is configured, gitorules prints an error and exits with code 2.

## Configuration: `.gitorules.yml`

gitorules reads a YAML config file (default: `.gitorules.yml`). This file defines which
repositories to manage and what branch protection rules to enforce.

### File structure

```
.gitorules.yml
├── orgs (multi-org mode)
│   └── <organization>
│       ├── repos      — list of repos
│       └── rules      — branch type definitions (see below)
│
└── org + repos + rules (single-org mode, shorthand)
```

### Multi-org mode

```yaml
orgs:
  unurgunite:
    repos:
      - docscribe
      - irb-autosuggestions
    rules:
      default_branch:
        merge: only
        checks:
          - "CI / build"

      release:
        pattern: v*
        squash: only

      system:
        pattern: system/*
        merge: only
```

### Rule types

| Key                  | Description                        | Values                                             |
|----------------------|------------------------------------|----------------------------------------------------|
| `pattern`            | Branch pattern (default: `master`) | Glob pattern or branch name                        |
| `merge`              | Merge method restriction           | `only`, `false` (omit for all methods)             |
| `rebase`             | Rebase method restriction          | `only`, `false`                                    |
| `squash`             | Squash method restriction          | `only`, `false`                                    |
| `checks`             | Required status checks             | List of check context strings                      |
| `required_approvals` | Required approving reviews         | Integer (default: 0)                               |
| `dismiss_stale`      | Dismiss approvals on new push      | `true`, `false` (default: `true`)                  |
| `require_code_owner` | Require code owner review          | `true`, `false` (default: `false`)                 |
| `enforce_admins`     | Enforce rules for admins           | `true`, `false` (default: `true`)                  |
| `deletion`           | Allow deletion (default: `true`)   | `true`, `false` — set to `false` to protect branch |
| `non_fast_forward`   | Allow non-fast-forward pushes      | `true`, `false` (default: `false`)                 |

### Single-org mode

For one organization, you can omit `orgs:` and use flat keys:

```yaml
org: unurgunite
repos:
  - docscribe
rules:
  default_branch:
    merge: only
```

---

### Branch types

Each key under `rules` is a **branch type** — a named group of branches that share
the same protection rules. You can define any name; the value becomes a column
in `gitorules status` output.

**Conventional types:**

| Type             | Default pattern | Matches                            | Typical use            |
|------------------|-----------------|------------------------------------|------------------------|
| `default_branch` | `master`        | `refs/heads/master`                | Main branch            |
| `release`        | `v*`            | `refs/heads/v1.0.0`, `v2.3.4`, ... | Release branches       |
| `system`         | `system/*`      | `refs/heads/system/*`              | CI/automation branches |

Any other key (e.g. `feature`, `dev`, `staging`) resolves to `refs/heads/{key}/*`.

---

### Branch type options

Each branch type supports these fields:

| Field            | Type       | Description                              | Default                        |
|------------------|------------|------------------------------------------|--------------------------------|
| `pattern`        | `string`   | Override the branch glob pattern         | See table above                |
| `name`           | `string`   | Custom ruleset display name              | Auto-generated (e.g. "master") |
| `merge`          | `"only"`   | Restrict to merge commits only           | Any method allowed             |
| `squash`         | `"only"`   | Restrict to squash merges only           | Any method allowed             |
| `rebase`         | `"only"`   | Restrict to rebase merges only           | Any method allowed             |
| `checks`         | `[string]` | Required status check contexts           | None required                  |
| `linear_history` | `bool`     | Require linear history (planned)         | `false`                        |
| `delete_branch`  | `bool`     | Auto-delete branch after merge (planned) | `false`                        |

#### `pattern`

Overrides the default branch glob for this type. The value is appended to
`refs/heads/`, so `v*` becomes `refs/heads/v*`.

```yaml
release:
  pattern: v*        # matches v1.0.0, v2.3.4, v2026.07, ...

feature:
  pattern: feat/*    # matches feat/settings, feat/export/abc
```

#### Merge methods: `merge`, `squash`, `rebase`

Exactly **one** method must be set to `"only"`. The GitHub API allows only
one merge method per ruleset. If none is set, all three methods are allowed.

```yaml
default_branch:
  merge: only        # ✓ merge commit  (no squash, no rebase)

release:
  squash: only       # ✓ squash commit (no merge, no rebase)
```

> [!NOTE]
> `"only"` is a string, not a boolean. `merge: true` does nothing.

#### `checks`

List of **status check context names** — these come directly from your GitHub
Actions workflows. When a workflow runs, GitHub posts checks named after the
workflow and job.

**How to find check names:**

```bash
# View check names for the latest commit on a branch
gh api repos/<org>/<repo>/commits/HEAD/check-runs --jq '.check_runs[].name'
```

The naming convention is `"<workflow name> / <job name>"`. For a workflow like:

```yaml
# .github/workflows/ci.yml
name: CI
jobs:
  build:
    runs-on: ubuntu-latest
```

The check context will be `"CI / build"`.

Example:

```yaml
default_branch:
  merge: only
  checks:
    - "CI / build"
    - "CI / lint"
    - "CI / test (1.20.0)"
```

> [!Warning]
> If the config requires checks that don't exist in the repository's CI, the ruleset will still be created, but
> the status checks will never pass (pending indefinitely).

#### `name`

By default, gitorules generates a display name from the branch type:

- `default_branch` -> `"master"`
- `release` -> `"Release branches — squash only"`
- custom -> `"{Type} branches"`

Overriding with `name` is useful when you want a specific name in the
GitHub UI or when renaming an existing ruleset:

```yaml
default_branch:
  name: "Main branch protection"
  merge: only
```

---

### What gitorules creates

For each branch type, gitorules creates a **GitHub ruleset** with these rules:

| Rule type                | Purpose                      | Always present?       |
|--------------------------|------------------------------|-----------------------|
| `deletion`               | Prevent branch deletion      | ✅ Always              |
| `non_fast_forward`       | Require up-to-date branch    | ✅ Always              |
| `pull_request`           | Require PR with merge method | ✅ Always              |
| `required_status_checks` | Enforce CI checks            | Only if `checks:` set |

The ruleset targets branches matching `refs/heads/{pattern}` and uses `enforcement: active` (fully enforced, not
"evaluate" or "disabled").

For `pull_request`, these parameters are always set:

| Parameter                           | Value                                            |
|-------------------------------------|--------------------------------------------------|
| `required_approving_review_count`   | `0`                                              |
| `dismiss_stale_reviews_on_push`     | `false`                                          |
| `require_code_owner_review`         | `false`                                          |
| `require_last_push_approval`        | `false`                                          |
| `required_review_thread_resolution` | `false`                                          |
| `allowed_merge_methods`             | `[method]` (only if `merge/squash/rebase: only`) |

---

### Config lookup logic

gitorules resolves which rules apply to a repository:

1. **Multi-org mode** (`orgs:`): finds the org that owns the repo by splitting
   `"org/repo"`, looks up rules in `orgs.<org>.rules`
2. **Single-org mode** (`org:` + `rules:`): uses top-level `rules` directly

If the owning org has no rules, the repo shows `✗ MISSING` for every branch type.

---

### `gitorules status` output

The table columns correspond to branch type keys from your config. Each cell shows:

| Status            | Meaning                                               |
|-------------------|-------------------------------------------------------|
| `✓ merge +checks` | Merge method OK, checks match (or extra checks found) |
| `✓ merge ~checks` | Merge method OK, but checks differ from config        |
| `✓ merge -checks` | Merge method OK, but no `required_status_checks` rule |
| `✗ merge`         | Merge method doesn't match config                     |
| `✗ MISSING`       | No ruleset found for this branch type                 |

Checks suffix:

- `+checks` — required checks present (possibly more)
- `~checks` — checks exist but don't match config exactly
- `-checks` — no checks rule at all

## Workflows sync

gitorules syncs GitHub Actions workflow files from local templates via the
Contents API, keeping `.github/workflows/` identical across repositories.

### Template layout

Declare workflows in `.gitorules.yml` (single-org mode shown; multi-org mode
supports `orgs.<org>.workflows` with the same shape):

```yaml
workflows:
  ci.yml:
    source: templates/ci.yml
```

Each key is the workflow file name; `source` is the local template path
(relative to the current directory). The key `ci.yml` syncs to
`.github/workflows/ci.yml` in every managed repository. Keys that already
carry the `.github/workflows/` prefix are used as-is.

### Allowlist

Only `.github/workflows/*.yml` (or `*.yaml`) targets are allowed — no
subdirectories, no path traversal. A disallowed target aborts the run with
exit code 2 before any API write.

### Behavior

- Matching blob shas are skipped silently (use `--verbose` to show them).
- Missing remote files are created; differing files are updated with the
  remote blob sha.
- `--dry-run` performs zero `PUT` requests and prints intentions instead.

### Token scopes

Workflow sync needs `contents:write` (covered by the classic `repo` scope).
For fine-grained tokens, grant **Contents** read and write on the managed
repositories.

### Node and VSCode stacks

Two templates cover Node.js projects. Both define a single `test` job —
the job name is part of the GitHub check context, so renaming it changes
required checks and must stay in sync with branch rules.

- `templates/node/ci.yml` — standard Node CI. Single `test` job on
  `ubuntu-latest` with a `node-version: [20, 22, 24]` matrix. Installs with
  `npm ci` (npm cache), then runs eslint, typecheck, and tests.
  Matrix checks look like `"CI / test (20)"` — verify real names with
  `gh api repos/<org>/<repo>/commits/HEAD/check-runs`.
- `templates/node/vscode-ci.yml` — VSCode extension pipeline. Single `test`
  job on `ubuntu-latest` with a `node-version: [18, 20, 22, 24]` by
  `vscode-version: [stable, insiders]` matrix. Runs format check
  (`npm run format:check`), lint, typecheck, compile, then extension tests
  under `xvfb` with retry (`nick-fields/retry`, 10 minute timeout,
  2 attempts).

```yaml
workflows:
  ci.yml:
    source: templates/node/ci.yml
  vscode-ci.yml:
    source: templates/node/vscode-ci.yml
```

Example branch rules for the standard Node template (matrix jobs produce
one check per combination):

```yaml
rules:
  default_branch:
    merge: only
    checks:
      - "CI / test (20)"
      - "CI / test (22)"
      - "CI / test (24)"
```

### Labels
Labels apply to every managed repository selected for the run.

```yaml
org: unurgunite
repos:
  - docscribe
rules:
  default_branch:
    merge: only
labels:
  - name: bug
    color: d73a4a
    description: Something is broken
  - name: help wanted
    color: "008672"
    description: Extra attention is needed
labels_sync: warn
```

| Field         | Type     | Description                          |
|---------------|----------|--------------------------------------|
| `name`        | `string` | Label name (unique per repository)   |
| `color`       | `string` | Hex color without `#` (e.g. `d73a4a`) |
| `description` | `string` | Short description (optional)         |

Color comparison is case-insensitive and ignores a leading `#`;
a missing description and an empty description are treated as equal.

#### Sync modes (`labels_sync`)

| Mode     | Missing labels | Differing labels | Orphan labels (not in config) |
|----------|----------------|------------------|-------------------------------|
| `warn` (default) | Created | Updated | Reported only, never deleted |
| `prune`  | Created | Updated | Deleted |
| `ignore` | Created | Updated | Skipped silently |

> [!WARNING]
> `labels_sync: prune` deletes every label that is not listed in
> `labels:`, including labels created manually or by other tools.
> Run `gitorules diff` first and review the `- Delete label` lines
> before applying with `prune`.

#### Token scopes

Label sync uses the same authentication as rulesets: a Personal
Access Token with `repo` and `read:org` scopes (or `GITHUB_TOKEN`
with those scopes). No additional scopes are required.

#### Limiting a run to labels

```shell
gitorules diff --only labels
gitorules apply --only labels --yes
gitorules status --only labels
```

Use `--only branch` to skip labels. `gitorules apply --dry-run`
performs zero writes for labels: creations, updates, and prune
deletions are only reported.

In JSON output (`--json`), each label change is an entry shaped
`{repo, resource, action, changes[]}` with `resource: "labels"`
and `action` one of `create`, `update`, `orphan`, `unchanged`.

## JSON output

`--json` emits machine-readable JSON with a unified entry shape across
`status`, `diff` and `apply`. Every per-resource entry carries:

| Field      | Type       | Description                                              |
|------------|------------|----------------------------------------------------------|
| `repo`     | `string`   | Full repository name (`owner/name`)                      |
| `resource` | `string`   | Ruleset display name (empty for repo-level errors)       |
| `action`   | `string`   | One of `create`, `update`, `unchanged`, `orphan`, `skip`, `error` |
| `changes`  | `[string]` | Human-readable differences (empty when none)             |

Legacy fields (`types`, `changes`, `results`, `name`, `exists`,
`merge_method_ok`, `checks_ok`, `error`) are kept for compatibility.

### Actions

- `create` — ruleset is missing and would be created.
- `update` — ruleset exists but differs from config.
- `unchanged` — ruleset matches config.
- `orphan` — ruleset exists on GitHub but has no matching branch type in config (diff only).
- `skip` — repo has no configured rules (unknown org in multi-org mode).
- `error` — API request failed; the entry also carries an `error` message field.

### Examples

```shell
gitorules status --json | jq '.[0].types.default_branch | {resource, action, changes}'
# {"resource":"master","action":"unchanged","changes":[]}

gitorules diff --json | jq '.[0].changes[] | {resource, action, changes}'
# {"resource":"master","action":"create","changes":[]}

gitorules apply --json --dry-run | jq '.[0].results[] | {resource, action, changes}'
```

### CI usage

```yaml
- name: Check rulesets
  run: |
    gitorules diff --json > diff.json
    if jq -e '[.[].changes[]? | select(.action == "create" or .action == "update")] | length > 0' diff.json > /dev/null; then
      echo "Ruleset drift detected"
      jq -r '.[] | select(.action == "error") | "\(.repo): \(.error)"' diff.json
      exit 1
    fi
```

Performance notes: repository listing follows GitHub `Link` pagination,
per-repo work runs in a bounded fiber pool (size 10, ordered output),
and API requests retry with exponential backoff on `429` and `5xx`.

## Development

```shell
shards install
crystal spec
./bin/ameba
crystal tool format --check
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).
