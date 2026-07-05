# gitorules

Declarative GitHub Ruleset Manager.

Manage branch protection rules across all your repositories from a single YAML config.

```yaml
org: unurgunite
rules:
  default_branch:
    merge: only
    checks: [ "check / check" ]
  release:
    pattern: "v*"
    squash: only
```

## Status

Early development. See [issues](https://github.com/unurgunite/gitorules/issues) for roadmap.
