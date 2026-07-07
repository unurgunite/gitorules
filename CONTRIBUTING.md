# Contributing

Thank you for your interest in contributing to gitorules!

## How to contribute

### Reporting bugs

Open an issue with a minimal reproduction. Include:

- Crystal version (`crystal --version`)
- gitorules version
- Your `.gitorules.yml` config (with secrets redacted)
- Expected vs actual output

### Suggesting features

Open an issue describing the use case and desired behaviour.

### Pull requests

1. Fork and create a branch from the latest release branch (e.g. `v0.1.0`).
2. Run `shards install` and ensure tests pass: `crystal spec`.
3. Run `./bin/ameba` — zero offenses required.
4. Run `crystal tool format` — no formatting changes.
5. Open a PR targeting the release branch.

## Development setup

```bash
git clone <your-fork>
cd gitorules
shards install
crystal spec
```

## Code conventions

- Target Crystal 1.14+.
- Follow existing code style (Ameba enforces it).
- YARD-style `@param` / `@return` documentation on all public methods.
- No external runtime dependencies (stdlib only).
