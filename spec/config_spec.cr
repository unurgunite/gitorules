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
  end
end
