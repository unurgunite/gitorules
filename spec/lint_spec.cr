require "./spec_helper"

module Gitorules
  describe Linter do
    describe ".lint_content" do
      it "accepts a valid single-org config" do
        result = Linter.lint_content(<<-YAML, "good.yml")
          org: unurgunite
          repos:
            - docscribe
          rules:
            default_branch:
              merge: only
              checks: ["CI / build"]
          YAML
        result.errors.should be_empty
      end

      it "accepts a valid defaults/scopes config" do
        result = Linter.lint_content(<<-YAML, "scoped.yml")
          defaults:
            rules:
              default_branch:
                merge: only
          scopes:
            backend:
              repos:
                - unurgunite/payment-api
              rules:
                release:
                  squash: only
          YAML
        result.errors.should be_empty
      end

      it "reports merge: true as an error with file and key hint" do
        result = Linter.lint_content(<<-YAML, "bad.yml")
          org: test
          repos:
            - r
          rules:
            default_branch:
              merge: true
          YAML
        result.errors.size.should eq 1
        result.errors.first.should contain "bad.yml"
        result.errors.first.should contain "rules.default_branch.merge"
        result.errors.first.should contain "true"
        result.errors.first.should contain "only"
        result.errors.first.should contain "Fix:"
      end

      it "rejects invalid string merge values" do
        result = Linter.lint_content(<<-YAML, ".gitorules.yml")
          org: test
          repos:
            - r
          rules:
            default_branch:
              merge: "nope"
          YAML
        result.errors.any?(&.includes?("rules.default_branch.merge")).should be_true
      end

      it "rejects non-string check entries and empty lists" do
        result = Linter.lint_content(<<-YAML, ".gitorules.yml")
          org: test
          repos:
            - r
          rules:
            default_branch:
              merge: only
              checks: []
          YAML
        result.errors.any?(&.includes?("checks")).should be_true
      end

      it "rejects conflicting merge methods" do
        result = Linter.lint_content(<<-YAML, ".gitorules.yml")
          org: test
          repos:
            - r
          rules:
            default_branch:
              merge: only
              squash: only
          YAML
        result.errors.any?(&.includes?("conflicting")).should be_true
      end

      it "rejects unknown rule fields" do
        result = Linter.lint_content(<<-YAML, ".gitorules.yml")
          org: test
          repos:
            - r
          rules:
            default_branch:
              merg: only
          YAML
        result.errors.any?(&.includes?("merg")).should be_true
      end

      it "rejects invalid YAML with a plain-language error" do
        result = Linter.lint_content("rules: [unclosed\n", "broken.yml")
        result.errors.size.should eq 1
        result.errors.first.should contain "broken.yml"
        result.errors.first.should contain "valid YAML"
      end

      it "rejects configs without any rules" do
        result = Linter.lint_content("org: test\n", ".gitorules.yml")
        result.errors.any?(&.includes?("no rules")).should be_true
      end

      it "warns on glob check patterns without failing" do
        result = Linter.lint_content(<<-YAML, ".gitorules.yml")
          org: test
          repos:
            - r
          rules:
            default_branch:
              merge: only
              checks: ["CI /*"]
          YAML
        result.errors.should be_empty
        result.warnings.size.should eq 1
        result.warnings.first.should contain "glob"
        result.warnings.first.should contain "gh api repos/<org>/<repo>/commits/HEAD/check-runs"
      end

      it "warns on check names without workflow prefix" do
        result = Linter.lint_content(<<-YAML, ".gitorules.yml")
          org: test
          repos:
            - r
          rules:
            default_branch:
              merge: only
              checks: ["mycheck"]
          YAML
        result.errors.should be_empty
        result.warnings.size.should eq 1
        result.warnings.first.should contain "mycheck"
        result.warnings.first.should contain "gh api repos/<org>/<repo>/commits/HEAD/check-runs"
      end

      it "does not warn on well-formed check names" do
        result = Linter.lint_content(<<-YAML, ".gitorules.yml")
          org: test
          repos:
            - r
          rules:
            default_branch:
              merge: only
              checks: ["CI / build"]
          YAML
        result.warnings.should be_empty
      end

      it "validates defaults and scopes rules" do
        result = Linter.lint_content(<<-YAML, "scoped.yml")
          defaults:
            rules:
              default_branch:
                merge: true
          scopes:
            backend:
              repos:
                - unurgunite/payment-api
              rules:
                release:
                  squash: only
                  rebase: only
          YAML
        result.errors.size.should eq 2
        result.errors.any?(&.includes?("defaults.rules.default_branch.merge")).should be_true
        result.errors.any?(&.includes?("conflicting")).should be_true
      end
    end

    describe ".lint_file" do
      it "returns 0 for a clean file" do
        path = File.join(Dir.tempdir, "lint-clean-#{Random.rand(100000)}.yml")
        File.write(path, "org: test\nrepos:\n  - r\nrules:\n  default_branch:\n    merge: only\n")
        io = IO::Memory.new
        err = IO::Memory.new
        Linter.lint_file(path, io, err).should eq 0
      ensure
        File.delete(path) if path && File.exists?(path)
      end

      it "returns 2 for a file with errors" do
        path = File.join(Dir.tempdir, "lint-bad-#{Random.rand(100000)}.yml")
        File.write(path, "org: test\nrepos:\n  - r\nrules:\n  default_branch:\n    merge: true\n")
        io = IO::Memory.new
        err = IO::Memory.new
        Linter.lint_file(path, io, err).should eq 2
        err.to_s.should contain "rules.default_branch.merge"
      end

      it "returns 2 for a missing file" do
        Linter.lint_file(File.join(Dir.tempdir, "lint-missing-#{Random.rand(100000)}.yml"), IO::Memory.new, IO::Memory.new).should eq 2
      end

      it "returns 0 with warnings only" do
        path = File.join(Dir.tempdir, "lint-warn-#{Random.rand(100000)}.yml")
        File.write(path, "org: test\nrepos:\n  - r\nrules:\n  default_branch:\n    merge: only\n    checks: [\"mycheck\"]\n")
        io = IO::Memory.new
        err = IO::Memory.new
        Linter.lint_file(path, io, err).should eq 0
        err.to_s.should contain "gh api repos"
      end
    end
  end

  describe Migrator do
    describe ".migrate_content" do
      it "converts the legacy fixture to defaults/scopes" do
        legacy = File.read(File.join(__DIR__, "fixtures", "legacy.yml"))
        migrated = Migrator.migrate_content(legacy)
        migrated.should contain "defaults:"
        migrated.should contain "scopes:"
        migrated.should contain "merge: only"
        migrated.should contain "unurgunite/docscribe"
        migrated.should contain "unurgunite/genius-api"
      end

      it "round-trips old-to-new without losing rules" do
        legacy = File.read(File.join(__DIR__, "fixtures", "legacy.yml"))
        migrated = Migrator.migrate_content(legacy)

        parsed = YAML.parse(migrated)
        top = parsed.as_h
        keys = top.keys.compact_map(&.as_s?)
        keys.should contain "defaults"
        keys.should contain "scopes"

        defaults_rules = parsed["defaults"]["rules"]
        defaults_rules["default_branch"]["merge"].as_s.should eq "only"
        defaults_rules["default_branch"]["checks"].as_a.map(&.as_s).should eq ["CI / build"]
        defaults_rules["release"]["squash"].as_s.should eq "only"

        repos = parsed["scopes"]["main"]["repos"].as_a.map(&.as_s)
        repos.should contain "unurgunite/docscribe"
        repos.should contain "unurgunite/genius-api"

        # Migrating again is a no-op (idempotent).
        Migrator.migrate_content(migrated).should eq migrated
      end

      it "converts multi-org configs to one scope per org" do
        migrated = Migrator.migrate_content(<<-YAML)
          orgs:
            unurgunite:
              repos:
                - docscribe
              rules:
                default_branch:
                  merge: only
            fintech:
              repos:
                - payment-api
              rules:
                default_branch:
                  squash: only
          YAML
        parsed = YAML.parse(migrated)
        parsed["scopes"]["unurgunite"]["repos"].as_a.map(&.as_s).should eq ["unurgunite/docscribe"]
        parsed["scopes"]["unurgunite"]["rules"]["default_branch"]["merge"].as_s.should eq "only"
        parsed["scopes"]["fintech"]["rules"]["default_branch"]["squash"].as_s.should eq "only"
      end

      it "expands short repo names to full org/repo names" do
        migrated = Migrator.migrate_content(<<-YAML)
          org: myorg
          repos:
            - api
          rules:
            default_branch:
              merge: only
          YAML
        YAML.parse(migrated)["scopes"]["main"]["repos"].as_a.map(&.as_s).should eq ["myorg/api"]
      end

      it "raises when there is nothing to migrate" do
        expect_raises(ArgumentError, /nothing to migrate/) do
          Migrator.migrate_content("foo: bar\n")
        end
      end
    end

    describe ".migrate_file" do
      it "prints to stdout by default without touching the file" do
        path = File.join(Dir.tempdir, "migrate-stdout-#{Random.rand(100000)}.yml")
        original = "org: test\nrepos:\n  - r\nrules:\n  default_branch:\n    merge: only\n"
        File.write(path, original)
        io = IO::Memory.new
        Migrator.migrate_file(path, false, io, IO::Memory.new).should eq 0
        io.to_s.should contain "scopes:"
        File.read(path).should eq original
      ensure
        File.delete(path) if path && File.exists?(path)
      end

      it "overwrites the file only with in_place" do
        path = File.join(Dir.tempdir, "migrate-inplace-#{Random.rand(100000)}.yml")
        File.write(path, "org: test\nrepos:\n  - r\nrules:\n  default_branch:\n    merge: only\n")
        Migrator.migrate_file(path, true, IO::Memory.new, IO::Memory.new).should eq 0
        File.read(path).should contain "scopes:"
      ensure
        File.delete(path) if path && File.exists?(path)
      end

      it "returns 2 for a missing file" do
        Migrator.migrate_file(File.join(Dir.tempdir, "migrate-missing-#{Random.rand(100000)}.yml"), false, IO::Memory.new, IO::Memory.new).should eq 2
      end
    end
  end

  describe "lint and migrate CLI" do
    it "lint exits 0 on a clean config without a token" do
      saved = ENV["GITHUB_TOKEN"]?
      ENV.delete("GITHUB_TOKEN")
      path = File.join(Dir.tempdir, "cli-lint-clean-#{Random.rand(100000)}.yml")
      File.write(path, "org: test\nrepos:\n  - r\nrules:\n  default_branch:\n    merge: only\n")
      CLI.run(["lint", "--config", path]).should eq 0
    ensure
      File.delete(path) if path && File.exists?(path)
      ENV["GITHUB_TOKEN"] = saved if saved
    end

    it "lint exits 2 on merge: true" do
      path = File.join(Dir.tempdir, "cli-lint-bad-#{Random.rand(100000)}.yml")
      File.write(path, "org: test\nrepos:\n  - r\nrules:\n  default_branch:\n    merge: true\n")
      CLI.run(["lint", "--config", path]).should eq 2
    ensure
      File.delete(path) if path && File.exists?(path)
    end

    it "migrate exits 2 for a missing file" do
      CLI.run(["migrate", "--config", File.join(Dir.tempdir, "cli-migrate-missing-#{Random.rand(100000)}.yml")]).should eq 2
    end

    it "migrate --in-place rewrites the file" do
      path = File.join(Dir.tempdir, "cli-migrate-#{Random.rand(100000)}.yml")
      File.write(path, "org: test\nrepos:\n  - r\nrules:\n  default_branch:\n    merge: only\n")
      CLI.run(["migrate", "--config", path, "--in-place"]).should eq 0
      File.read(path).should contain "scopes:"
    ensure
      File.delete(path) if path && File.exists?(path)
    end
  end
end
