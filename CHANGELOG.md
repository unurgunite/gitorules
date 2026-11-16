# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] — 2026-11-16

A maintenance release: no new user-facing features, but one silent data-loss
bug fixed, `--dry-run` made trustworthy across every command, and the lint
gate turned from decoration into something that actually fails a build.

### Added

- `CHANGELOG.md`.
- **catalyst** and **ameba-method_length** as development dependencies, wired
  through `bin/ameba.cr`. `Metrics/MethodLength` is configured at
  `MaxLines: 15` with `CountAsOne` for arrays, hashes and heredocs, matching
  the sibling shards so the same method body lints identically in every repo.
- `Options#config_path` and `Options#in_place?`, so option parsing and command
  dispatch share one source of truth.

### Changed

- **Crystal 1.22.3** everywhere: `shard.yml` floor raised to `>= 1.22.0`, CI
  and release workflows pinned from 1.21.0. The CI matrix now pins a single
  compiler version across all four OS legs, so a compiler change can no longer
  land on one leg unnoticed.
- `apply --dry-run` no longer asks the `Proceed?` confirmation. A preview that
  cannot be confirmed has nothing to confirm.
- `--dry-run` help text now describes the flag's real scope instead of
  mentioning only `apply`.
- `status_print_header` builds its table row with `String.build` and `pad_to`
  instead of string concatenation in a loop.

### Fixed

- **`migrate --in-place --dry-run` overwrote the config file.** The flag was
  parsed and then ignored, so a preview destroyed the file it was previewing.
  It now prints `Dry run: ... would be migrated` and writes nothing.
- **`Options` was a struct, so every parsed flag was silently discarded.**
  `OptionParser` blocks receive the option object as a block parameter, and a
  struct block parameter is a copy — writes vanished. `Options` is now a class.
  This affected all flags, and the parser appeared to succeed while doing so.
- **`merge:` / `squash:` / `rebase:` were dropped when generating a config from
  an existing repository.** `BranchRuleConfig` is a struct, so the new
  `extract_config` helpers mutated a copy. `init` now emits `merge: only` and
  friends again.
- Duplicate `verbose` property in `Options`; the documented one is kept.
- Read-only commands (`status`, `diff`, `lint`, `verify`) still warn that
  `--dry-run` has no effect for them, rather than pretending to honour it.

### Internal

- ameba findings **62 → 0**; catalyst findings **10 → 0**. Nearly all of it is
  cohesive method extraction across `cli.cr`, `lint.cr`, `branch_rules.cr`,
  `verify.cr`, `scope.cr`, `config.cr`, `init.cr`, `github.cr`, `labels.cr`,
  `workflows.cr`, `concurrent.cr`, `types.cr` and `template_source.cr`.
- `bin/ameba.cr` is now tracked. The `/bin/` ignore rule (meant for `shards
  build` output) had been swallowing it, so every non-Windows CI leg failed
  with `target ameba failed to compile: bin/ameba.cr: No such file`. Windows
  hid the bug because its lint step is skipped.
- `check-source` now runs only for PRs into `master`, where the `v*`/`system/*`
  source-branch rule applies. Previously it reported `skipping` on every other
  PR, which left the PR status stuck on `UNSTABLE` and blocked a clean green.
- Removed dead `matrix.crystal == '1.22.3'` guards left behind when the matrix
  was pinned to one version.
- Regression fixes caught only by `crystal spec`, not by compilation: an
  `all?`-truthiness bug and an empty-axes case in `verify.cr` matrix expansion,
  index arithmetic in `scope.cr` glob translation, and the struct-copy drops
  above. Test count 360 → 362.

### Verification

`crystal spec`: 362 examples, 0 failures. `bin/ameba`: 40 inspected, 0
failures. `catalyst src/`: exit 0. `crystal tool format --check`: clean.
`gitorules lint --config .gitorules.yml.example`: exit 0. CI green on Ubuntu,
macOS (arm64 and Intel) and Windows.

## [0.3.1]

Previous release. See the git history for details.

[0.4.0]: https://github.com/unurgunite/gitorules/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/unurgunite/gitorules/releases/tag/v0.3.1
