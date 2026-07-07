<h1 align="center">gitorules</h1>

<p align="center">
<a href="https://github.com/unurgunite/gitorules/actions"><img src="https://github.com/unurgunite/gitorules/actions/workflows/ci.yml/badge.svg?branch=master" alt="CI"></a>
<a href="https://github.com/unurgunite/gitorules/blob/master/LICENSE"><img src="https://img.shields.io/github/license/unurgunite/gitorules.svg" alt="License"></a>
<a href="https://crystal-lang.org"><img src="https://img.shields.io/badge/crystal-%3E%3D%201.12-blue.svg" alt="Crystal"></a>
</p>

Declarative GitHub Ruleset Manager.

Manage branch protection rules across all your repositories from a single YAML config.

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

Requires Crystal 1.12+.

## CLI

```shell
gitorules <status|apply|diff|init> [options]
```

### Commands

| Command    | Description                                      |
|------------|--------------------------------------------------|
| `status`   | Show ruleset status for repositories             |
| `apply`    | Apply ruleset configuration from `.gitorules.yml` |
| `diff`     | Show pending changes without applying             |
| `init`     | Generate `.gitorules.yml` from existing rulesets  |

### Options

| Flag                     | Description                                        |
|--------------------------|----------------------------------------------------|
| `--dry-run`              | Preview apply changes without making them          |
| `--diff`                 | Show pending changes (same as `diff` command)      |
| `--repo REPO`            | Target a single repository (`owner/name`)          |
| `--org ORG`              | GitHub organization name (for `init`)              |
| `--json`                 | Machine-readable JSON output                       |
| `--quiet`                | Suppress all output except errors                  |
| `--token TOKEN`          | GitHub personal access token                       |
| `--app-id ID`            | GitHub App ID (for GitHub App auth)                |
| `--private-key PEM`      | GitHub App private key (PEM content)               |
| `--private-key-path PATH`| Path to GitHub App private key PEM file            |
| `--installation-id ID`   | GitHub App installation ID                         |
| `--config PATH`          | Path to config file (default: `.gitorules.yml`)    |
| `--version`              | Show version                                       |
| `-h`, `--help`           | Show help                                          |

### Exit codes

- **0** — all rulesets are up to date (no changes needed)
- **1** — changes detected (in status/diff mode) or changes applied (in apply mode)
- **2** — execution error (config error, API error, etc.)

### Authentication

gitorules supports two authentication methods:

**Personal Access Token:**

```shell
gitorules --token ghp_xxx status
```

Or set `GITHUB_TOKEN` environment variable.

**GitHub App (JWT):**

```shell
gitorules --app-id 123456 --private-key-path ./key.pem --installation-id 789012 status
```

Environment variables: `GITHUB_APP_ID`, `GITHUB_APP_PRIVATE_KEY`, `GITHUB_APP_INSTALLATION_ID`.

If no auth method is configured, gitorules prints an error and exits with code 2.

## Configuration

gitorules uses a `.gitorules.yml` file in the project root. Example:

```yaml
orgs:
  myorg:
    repos:
      - repo-a
      - repo-b
    rules:
      default_branch:
        merge: only
        checks:
          - "check / check"

      release:
        pattern: v*
        squash: only

      system:
        pattern: system/*
        merge: only
```

### Rule types

| Key               | Description                                | Values                                            |
|-------------------|--------------------------------------------|---------------------------------------------------|
| `pattern`         | Branch pattern (default: `master`)         | Glob pattern or branch name                       |
| `merge`           | Merge method restriction                   | `only`, `false` (omit for all methods)            |
| `rebase`          | Rebase method restriction                  | `only`, `false`                                   |
| `squash`          | Squash method restriction                  | `only`, `false`                                   |
| `checks`          | Required status checks                     | List of check context strings                     |
| `required_approvals` | Required approving reviews              | Integer (default: 0)                              |
| `dismiss_stale`   | Dismiss approvals on new push              | `true`, `false` (default: `true`)                 |
| `require_code_owner` | Require code owner review               | `true`, `false` (default: `false`)                |
| `enforce_admins`  | Enforce rules for admins                   | `true`, `false` (default: `true`)                 |
| `deletion`        | Allow deletion (default: `true`)           | `true`, `false` — set to `false` to protect branch |
| `non_fast_forward`| Allow non-fast-forward pushes              | `true`, `false` (default: `false`)                |

### Single-org mode

For a single organization, you can use the shorthand:

```yaml
org: myorg
repos:
  - repo-a
rules:
  default_branch:
    merge: only
```

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
