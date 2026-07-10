<h1 align="center">gitorules</h1>

<p align="center">
<a href="https://github.com/unurgunite/gitorules/actions"><img src="https://github.com/unurgunite/gitorules/actions/workflows/ci.yml/badge.svg?branch=master" alt="CI"></a>
<a href="https://github.com/unurgunite/gitorules/blob/master/LICENSE"><img src="https://img.shields.io/github/license/unurgunite/gitorules.svg" alt="License"></a>
<a href="https://crystal-lang.org"><img src="https://img.shields.io/badge/crystal-%3E%3D%201.14-blue.svg" alt="Crystal"></a>
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

Requires Crystal 1.14+.

## CLI

```shell
gitorules <status|apply|diff|init> [options]
```

### Commands

| Command  | Description                                       |
|----------|---------------------------------------------------|
| `status` | Show ruleset status for repositories              |
| `apply`  | Apply ruleset configuration from `.gitorules.yml` |
| `diff`   | Show pending changes without applying             |
| `init`   | Generate `.gitorules.yml` from existing rulesets  |

### Options

| Flag            | Description                                     |
|-----------------|-------------------------------------------------|
| `--dry-run`     | Preview apply changes without making them       |
| `--diff`        | Show pending changes (same as `diff` command)   |
| `--repo REPO`   | Target a single repository (`owner/name`)       |
| `--org ORG`     | GitHub organization name (for `init`)           |
| `--json`        | Machine-readable JSON output                    |
| `--quiet`       | Suppress all output except errors               |
| `--yes`         | Skip confirmation prompt and apply immediately  |
| `--token TOKEN` | GitHub personal access token                    |
| `--config PATH` | Path to config file (default: `.gitorules.yml`) |
| `--version`     | Show version                                    |
| `-h`, `--help`  | Show help                                       |

**Apply confirmation:**

Before applying changes, `gitorules apply` shows a diff and asks for confirmation. Use `--yes` to skip the prompt in
scripts/automation.

### Exit codes

- **0** — all rulesets are up to date (no changes needed)
- **1** — changes detected (in `diff` mode) or changes were applied (in `apply` mode). Also returned when the
  confirmation prompt is declined (changes exist but were skipped)
- **2** — execution error (config error, API error, etc.)

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
