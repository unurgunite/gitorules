require "./spec_helper"

module Gitorules
  TMP_DIR = Dir.tempdir

  describe ConfigLoader do
    token = "test-token"

    describe "#initialize" do
      it "reads YAML config from file" do
        config_yaml = <<-YAML
          org: unurgunite
          repos:
            - docscribe
          rules:
            default_branch:
              merge: only
              checks: ["check / check"]
            release:
              pattern: "v*"
              squash: only
          YAML

        path = File.join(Gitorules::TMP_DIR, "test_gitorules_read.yml")
        File.write(path, config_yaml)
        loader = ConfigLoader.new(path, token)
        loader.config.org.should eq "unurgunite"
        loader.config.repos.should eq ["docscribe"]
        loader.config.rules.should be_a(Hash(String, BranchRuleConfig))
      ensure
        File.delete(path) if path && File.exists?(path)
      end

      it "falls back to GITHUB_TOKEN env" do
        config_yaml = "org: unurgunite\nrepos:\n  - docscribe\nrules:\n  default_branch:\n    merge: only\n"
        path = File.join(Gitorules::TMP_DIR, "test_gitorules_env.yml")
        File.write(path, config_yaml)

        ENV["GITHUB_TOKEN"] = "env-token"
        loader = ConfigLoader.new(path)
        loader.token.should eq "env-token"
      ensure
        File.delete(path) if path && File.exists?(path)
        ENV.delete("GITHUB_TOKEN")
      end

      it "raises without token" do
        config_yaml = "org: unurgunite\nrepos:\n  - docscribe\nrules:\n  default_branch:\n    merge: only\n"
        path = File.join(Gitorules::TMP_DIR, "test_gitorules_notoken.yml")
        File.write(path, config_yaml)

        expect_raises(Exception, "GITHUB_TOKEN not set") do
          ConfigLoader.new(path)
        end
      ensure
        File.delete(path) if path && File.exists?(path)
      end
    end

    describe "validation" do
      token = "test-token"

      it "accepts valid config without error" do
        config_yaml = "org: test\nrepos:\n  - r\nrules:\n  default_branch:\n    merge: only\n    checks: [\"c\"]\n  release:\n    squash: only\n"
        path = File.join(Gitorules::TMP_DIR, "test_validate_ok.yml")
        File.write(path, config_yaml)
        loader = ConfigLoader.new(path, token)
        loader.config.rules.should_not be_nil
      ensure
        File.delete(path) if path && File.exists?(path)
      end

      it "rejects boolean merge method" do
        config_yaml = "org: test\nrepos:\n  - r\nrules:\n  default_branch:\n    merge: true\n"
        path = File.join(Gitorules::TMP_DIR, "test_validate_bool.yml")
        File.write(path, config_yaml)
        expect_raises(Exception, /expected .only. or nil/) do
          ConfigLoader.new(path, token)
        end
      ensure
        File.delete(path) if path && File.exists?(path)
      end

      it "rejects invalid string merge method" do
        config_yaml = "org: test\nrepos:\n  - r\nrules:\n  default_branch:\n    merge: \"nope\"\n"
        path = File.join(Gitorules::TMP_DIR, "test_validate_str.yml")
        File.write(path, config_yaml)
        expect_raises(Exception, /expected .only. or nil/) do
          ConfigLoader.new(path, token)
        end
      ensure
        File.delete(path) if path && File.exists?(path)
      end

      it "reports all invalid fields in one error" do
        config_yaml = "org: test\nrepos:\n  - r\nrules:\n  default_branch:\n    merge: true\n    squash: 123\n"
        path = File.join(Gitorules::TMP_DIR, "test_validate_multi.yml")
        File.write(path, config_yaml)
        expect_raises(Exception, /merge/) do
          ConfigLoader.new(path, token)
        end
      ensure
        File.delete(path) if path && File.exists?(path)
      end

      it "accepts linear_history with warning (no error)" do
        config_yaml = "org: test\nrepos:\n  - r\nrules:\n  default_branch:\n    merge: only\n    linear_history: true\n"
        path = File.join(Gitorules::TMP_DIR, "test_validate_linear.yml")
        File.write(path, config_yaml)
        loader = ConfigLoader.new(path, token)
        loader.config.rules.should_not be_nil
      ensure
        File.delete(path) if path && File.exists?(path)
      end

      it "accepts delete_branch with warning (no error)" do
        config_yaml = "org: test\nrepos:\n  - r\nrules:\n  default_branch:\n    merge: only\n    delete_branch: true\n"
        path = File.join(Gitorules::TMP_DIR, "test_validate_delete.yml")
        File.write(path, config_yaml)
        loader = ConfigLoader.new(path, token)
        loader.config.rules.should_not be_nil
      ensure
        File.delete(path) if path && File.exists?(path)
      end

      it "rejects config with two merge methods" do
        config_yaml = "org: test\nrepos:\n  - r\nrules:\n  default_branch:\n    merge: only\n    squash: only\n"
        path = File.join(Gitorules::TMP_DIR, "test_merge_conflict.yml")
        File.write(path, config_yaml)
        expect_raises(Exception, /conflicting/) do
          ConfigLoader.new(path, token)
        end
      ensure
        File.delete(path) if path && File.exists?(path)
      end

      it "rejects config with three merge methods" do
        config_yaml = "org: test\nrepos:\n  - r\nrules:\n  default_branch:\n    merge: only\n    squash: only\n    rebase: only\n"
        path = File.join(Gitorules::TMP_DIR, "test_merge_conflict3.yml")
        File.write(path, config_yaml)
        expect_raises(Exception, /conflicting/) do
          ConfigLoader.new(path, token)
        end
      ensure
        File.delete(path) if path && File.exists?(path)
      end

      it "accepts config with single merge method" do
        config_yaml = "org: test\nrepos:\n  - r\nrules:\n  default_branch:\n    merge: only\n"
        path = File.join(Gitorules::TMP_DIR, "test_merge_single.yml")
        File.write(path, config_yaml)
        loader = ConfigLoader.new(path, token)
        loader.config.rules.should_not be_nil
      ensure
        File.delete(path) if path && File.exists?(path)
      end

      it "rejects multi-org config with conflicting merge methods" do
        config_yaml = <<-YAML
          orgs:
            unurgunite:
              repos:
                - docscribe
              rules:
                default_branch:
                  merge: only
                  squash: only
          YAML
        path = File.join(Gitorules::TMP_DIR, "test_merge_conflict_multi.yml")
        File.write(path, config_yaml)
        expect_raises(Exception, /conflicting/) do
          ConfigLoader.new(path, token)
        end
      ensure
        File.delete(path) if path && File.exists?(path)
      end

      it "validates multi-org rules" do
        config_yaml = <<-YAML
          orgs:
            unurgunite:
              repos:
                - docscribe
              rules:
                default_branch:
                  merge: only
                release:
                  squash: 42
          YAML
        path = File.join(Gitorules::TMP_DIR, "test_validate_multi.yml")
        File.write(path, config_yaml)
        expect_raises(Exception, /unurgunite.release.squash/) do
          ConfigLoader.new(path, token)
        end
      ensure
        File.delete(path) if path && File.exists?(path)
      end
    end

    describe "#repo_names" do
      it "returns explicit repos list" do
        config_yaml = "org: unurgunite\nrepos:\n  - docscribe\n  - genius-api\nrules:\n  default_branch:\n    merge: only\n"
        path = File.join(Gitorules::TMP_DIR, "test_gitorules_repos.yml")
        File.write(path, config_yaml)
        loader = ConfigLoader.new(path, token)

        names = loader.repo_names
        names.should eq ["docscribe", "genius-api"]
      ensure
        File.delete(path) if path && File.exists?(path)
      end

      it "discovers repos via API when repos not set" do
        config_yaml = "org: testorg\nrules:\n  default_branch:\n    merge: only\n"
        path = File.join(Gitorules::TMP_DIR, "test_gitorules_discover.yml")
        File.write(path, config_yaml)

        WebMock.stub(:get, "https://api.github.com/orgs/testorg/repos?per_page=100&type=owner")
          .to_return(body: %([{"name": "repo1"}, {"name": "repo2"}]),
            headers: {"Content-Type" => "application/json"})

        loader = ConfigLoader.new(path, token)
        names = loader.repo_names
        names.should eq ["testorg/repo1", "testorg/repo2"]
      ensure
        File.delete(path) if path && File.exists?(path)
        WebMock.reset
      end

      it "raises when neither repos nor org is set" do
        config_yaml = "rules:\n  default_branch:\n    merge: only\n"
        path = File.join(Gitorules::TMP_DIR, "test_gitorules_none.yml")
        File.write(path, config_yaml)

        expect_raises(Exception, "No repos or org in config") do
          loader = ConfigLoader.new(path, token)
          loader.repo_names
        end
      ensure
        File.delete(path) if path && File.exists?(path)
      end
    end

    describe "multi-org" do
      it "parses orgs config and returns prefixed repo names" do
        config_yaml = <<-YAML
          orgs:
            unurgunite:
              repos:
                - docscribe
                - gitorules
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

        path = File.join(Gitorules::TMP_DIR, "test_gitorules_multi.yml")
        File.write(path, config_yaml)
        loader = ConfigLoader.new(path, token)
        names = loader.repo_names
        names.should contain("unurgunite/docscribe")
        names.should contain("unurgunite/gitorules")
        names.should contain("fintech/payment-api")
      ensure
        File.delete(path) if path && File.exists?(path)
      end

      it "returns correct rules per repo via rules_for" do
        config_yaml = <<-YAML
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

        path = File.join(Gitorules::TMP_DIR, "test_gitorules_rules_for.yml")
        File.write(path, config_yaml)
        loader = ConfigLoader.new(path, token)

        unurgunite_rules = loader.config.rules_for("unurgunite/docscribe")
        unurgunite_rules.should_not be_nil
        unurgunite_rules.try(&.["default_branch"].merge).should eq "only"

        fintech_rules = loader.config.rules_for("fintech/payment-api")
        fintech_rules.should_not be_nil
        fintech_rules.try(&.["default_branch"].squash).should eq "only"
      ensure
        File.delete(path) if path && File.exists?(path)
      end

      it "all_type_keys aggregates types from all orgs" do
        config_yaml = <<-YAML
          orgs:
            unurgunite:
              repos:
                - docscribe
              rules:
                default_branch:
                  merge: only
                release:
                  squash: only
            fintech:
              repos:
                - payment-api
              rules:
                default_branch:
                  squash: only
                hotfix:
                  merge: only
          YAML

        path = File.join(Gitorules::TMP_DIR, "test_gitorules_all_types.yml")
        File.write(path, config_yaml)
        loader = ConfigLoader.new(path, token)
        keys = loader.config.all_type_keys
        keys.should contain("default_branch")
        keys.should contain("release")
        keys.should contain("hotfix")
      ensure
        File.delete(path) if path && File.exists?(path)
      end
    end

    describe "scopes" do
      it "parses defaults and named scopes" do
        config_yaml = <<-YAML
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
            frontend:
              repos:
                - unurgunite/docscribe
          YAML

        path = File.join(Gitorules::TMP_DIR, "test_scopes_parse.yml")
        File.write(path, config_yaml)
        loader = ConfigLoader.new(path, token)
        loader.scope_names.sort.should eq ["backend", "frontend"]
        loader.config.defaults.should_not be_nil
      ensure
        File.delete(path) if path && File.exists?(path)
      end

      it "resolves effective rules with defaults fallback" do
        config = Config.from_yaml(<<-YAML)
          defaults:
            rules:
              default_branch:
                merge: only
                checks: ["check / check"]
          scopes:
            backend:
              repos:
                - unurgunite/payment-api
              rules:
                release:
                  squash: only
          YAML

        resolver = ScopeResolver.new(config)
        rules = resolver.effective_rules("unurgunite/payment-api")
        if rules
          rules.keys.should contain("default_branch")
          rules.keys.should contain("release")
          rules["default_branch"].merge.should eq "only"
          rules["release"].squash.should eq "only"
        else
          fail "expected effective rules"
        end
      end

      it "scope rules override defaults per field" do
        config = Config.from_yaml(<<-YAML)
          defaults:
            rules:
              default_branch:
                merge: only
                checks: ["check / check"]
          scopes:
            backend:
              repos:
                - unurgunite/payment-api
              rules:
                default_branch:
                  squash: only
          YAML

        resolver = ScopeResolver.new(config)
        rules = resolver.effective_rules("unurgunite/payment-api")
        if rules
          rules["default_branch"].squash.should eq "only"
          rules["default_branch"].merge.should be_nil
          rules["default_branch"].checks.should eq ["check / check"]
        else
          fail "expected effective rules"
        end
      end

      it "rules_for returns merged scope rules" do
        config = Config.from_yaml(<<-YAML)
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

        rules = config.rules_for("unurgunite/payment-api")
        if rules
          rules.keys.should contain("default_branch")
          rules.keys.should contain("release")
        else
          fail "expected merged scope rules"
        end
      end

      it "all_type_keys aggregates defaults and scopes" do
        config = Config.from_yaml(<<-YAML)
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
            frontend:
              repos:
                - unurgunite/docscribe
              rules:
                hotfix:
                  merge: only
          YAML

        keys = config.all_type_keys
        keys.should contain("default_branch")
        keys.should contain("release")
        keys.should contain("hotfix")
      end

      it "expands glob selectors against available repos" do
        config = Config.from_yaml(<<-YAML)
          scopes:
            backend:
              repos:
                - unurgunite/*-api
              rules:
                default_branch:
                  merge: only
          YAML

        resolver = ScopeResolver.new(config)
        available = ["unurgunite/payment-api", "unurgunite/docscribe", "unurgunite/billing-api"]
        repos = resolver.repos_for_scope("backend", available)
        repos.should contain("unurgunite/payment-api")
        repos.should contain("unurgunite/billing-api")
        repos.should_not contain("unurgunite/docscribe")
      end

      it "matches glob patterns" do
        ScopeResolver.matches?("unurgunite/*-api", "unurgunite/payment-api").should be_true
        ScopeResolver.matches?("unurgunite/*-api", "unurgunite/docscribe").should be_false
        ScopeResolver.matches?("unurgunite/payment-api", "unurgunite/payment-api").should be_true
        ScopeResolver.matches?("*", "unurgunite/anything").should be_true
        ScopeResolver.matches?("*-api", "unurgunite/payment-api").should be_true
      end

      it "applies explicit exclude list" do
        config = Config.from_yaml(<<-YAML)
          scopes:
            backend:
              repos:
                - unurgunite/*-api
              exclude:
                - unurgunite/legacy-api
              rules:
                default_branch:
                  merge: only
          YAML

        resolver = ScopeResolver.new(config)
        available = ["unurgunite/payment-api", "unurgunite/legacy-api"]
        repos = resolver.repos_for_scope("backend", available)
        repos.should contain("unurgunite/payment-api")
        repos.should_not contain("unurgunite/legacy-api")
      end

      it "supports glob patterns in exclude" do
        config = Config.from_yaml(<<-YAML)
          scopes:
            backend:
              repos:
                - unurgunite/*
              exclude:
                - unurgunite/legacy-*
              rules:
                default_branch:
                  merge: only
          YAML

        resolver = ScopeResolver.new(config)
        available = ["unurgunite/payment-api", "unurgunite/legacy-api"]
        repos = resolver.repos_for_scope("backend", available)
        repos.should contain("unurgunite/payment-api")
        repos.should_not contain("unurgunite/legacy-api")
      end

      it "filters repos via CLI exclude patterns" do
        repos = ["unurgunite/payment-api", "unurgunite/docscribe"]
        filtered = ScopeResolver.filter_exclude(repos, ["unurgunite/docscribe"])
        filtered.should eq ["unurgunite/payment-api"]
        filtered_glob = ScopeResolver.filter_exclude(repos, ["unurgunite/*-api"])
        filtered_glob.should eq ["unurgunite/docscribe"]
      end

      it "loads legacy single-org config as default scope" do
        config_yaml = <<-YAML
          org: unurgunite
          repos:
            - docscribe
          rules:
            default_branch:
              merge: only
          YAML

        path = File.join(Gitorules::TMP_DIR, "test_scopes_legacy_single.yml")
        File.write(path, config_yaml)
        loader = ConfigLoader.new(path, token)
        loader.scope_names.should eq ["default"]
        loader.repos_for_scope("default").should eq ["docscribe"]
        rules = loader.config.rules_for("docscribe")
        rules.should_not be_nil
      ensure
        File.delete(path) if path && File.exists?(path)
      end

      it "loads legacy multi-org config as default scope" do
        config_yaml = <<-YAML
          orgs:
            unurgunite:
              repos:
                - docscribe
              rules:
                default_branch:
                  merge: only
          YAML

        path = File.join(Gitorules::TMP_DIR, "test_scopes_legacy_multi.yml")
        File.write(path, config_yaml)
        loader = ConfigLoader.new(path, token)
        loader.scope_names.should eq ["default"]
        rules = loader.config.rules_for("unurgunite/docscribe")
        if rules
          rules["default_branch"].merge.should eq "only"
        else
          fail "expected legacy multi-org rules"
        end
      ensure
        File.delete(path) if path && File.exists?(path)
      end

      it "raises UnknownScopeError for unknown scope" do
        config = Config.from_yaml(<<-YAML)
          scopes:
            backend:
              repos:
                - unurgunite/payment-api
          YAML

        resolver = ScopeResolver.new(config)
        expect_raises(UnknownScopeError, /Available scopes: backend/) do
          resolver.validate_scope!("nope")
        end
      end

      it "CLI returns exit code 2 for unknown scope" do
        config_yaml = <<-YAML
          scopes:
            backend:
              repos:
                - unurgunite/payment-api
              rules:
                default_branch:
                  merge: only
          YAML

        path = File.join(Gitorules::TMP_DIR, "test_scopes_unknown_cli.yml")
        File.write(path, config_yaml)
        code = CLI.run(["--token", token, "--config", path, "diff", "--scope", "nope"])
        code.should eq 2
      ensure
        File.delete(path) if path && File.exists?(path)
      end

      it "parses --only values" do
        ScopeResolver.parse_only(nil).should be_nil
        ScopeResolver.parse_only("").should be_nil
        ScopeResolver.parse_only("branch,labels").should eq Set{"branch", "labels"}
        expect_raises(ArgumentError, /Valid values/) do
          ScopeResolver.parse_only("branch,bogus")
        end
      end

      it "rejects invalid scope rules" do
        config_yaml = <<-YAML
          scopes:
            backend:
              repos:
                - unurgunite/payment-api
              rules:
                default_branch:
                  merge: "nope"
          YAML

        path = File.join(Gitorules::TMP_DIR, "test_scopes_invalid.yml")
        File.write(path, config_yaml)
        expect_raises(Exception, /expected .only. or nil/) do
          ConfigLoader.new(path, token)
        end
      ensure
        File.delete(path) if path && File.exists?(path)
      end

      it "rejects conflicting merge methods in scopes" do
        config_yaml = <<-YAML
          scopes:
            backend:
              repos:
                - unurgunite/payment-api
              rules:
                default_branch:
                  merge: only
                  squash: only
          YAML

        path = File.join(Gitorules::TMP_DIR, "test_scopes_conflict.yml")
        File.write(path, config_yaml)
        expect_raises(Exception, /conflicting/) do
          ConfigLoader.new(path, token)
        end
      ensure
        File.delete(path) if path && File.exists?(path)
      end

      it "expands globs via API discovery when no available list given" do
        config_yaml = <<-YAML
          scopes:
            backend:
              repos:
                - testorg/*-api
              rules:
                default_branch:
                  merge: only
          YAML

        path = File.join(Gitorules::TMP_DIR, "test_scopes_discover.yml")
        File.write(path, config_yaml)

        WebMock.stub(:get, "https://api.github.com/orgs/testorg/repos?per_page=100&type=owner")
          .to_return(body: %([{"name": "payment-api"}, {"name": "docs"}]),
            headers: {"Content-Type" => "application/json"})

        loader = ConfigLoader.new(path, token)
        repos = loader.repos_for_scope("backend")
        repos.should contain("testorg/payment-api")
        repos.should_not contain("testorg/docs")
      ensure
        File.delete(path) if path && File.exists?(path)
        WebMock.reset
      end
    end
  end
end
