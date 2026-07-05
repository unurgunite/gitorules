require "./spec_helper"

module Gitorules
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

        File.write("/tmp/test_gitorules.yml", config_yaml)
        loader = ConfigLoader.new("/tmp/test_gitorules.yml", token)
        loader.config.org.should eq "unurgunite"
        loader.config.repos.should eq ["docscribe"]
        loader.config.rules.should be_a(Hash(String, BranchRuleConfig))
      ensure
        File.delete("/tmp/test_gitorules.yml") if File.exists?("/tmp/test_gitorules.yml")
      end

      it "falls back to GITHUB_TOKEN env" do
        config_yaml = "org: unurgunite\nrepos:\n  - docscribe\nrules:\n  default_branch:\n    merge: only\n"
        File.write("/tmp/test_gitorules_env.yml", config_yaml)

        ENV["GITHUB_TOKEN"] = "env-token"
        loader = ConfigLoader.new("/tmp/test_gitorules_env.yml")
        loader.token.should eq "env-token"
      ensure
        File.delete("/tmp/test_gitorules_env.yml") if File.exists?("/tmp/test_gitorules_env.yml")
        ENV.delete("GITHUB_TOKEN")
      end

      it "raises without token" do
        config_yaml = "org: unurgunite\nrepos:\n  - docscribe\nrules:\n  default_branch:\n    merge: only\n"
        File.write("/tmp/test_gitorules_notoken.yml", config_yaml)

        expect_raises(Exception, "GITHUB_TOKEN not set") do
          ConfigLoader.new("/tmp/test_gitorules_notoken.yml")
        end
      ensure
        File.delete("/tmp/test_gitorules_notoken.yml") if File.exists?("/tmp/test_gitorules_notoken.yml")
      end
    end

    describe "#repo_names" do
      it "returns explicit repos list" do
        config_yaml = "org: unurgunite\nrepos:\n  - docscribe\n  - genius-api\nrules:\n  default_branch:\n    merge: only\n"
        File.write("/tmp/test_gitorules_repos.yml", config_yaml)
        loader = ConfigLoader.new("/tmp/test_gitorules_repos.yml", token)

        names = loader.repo_names
        names.should eq ["docscribe", "genius-api"]
      ensure
        File.delete("/tmp/test_gitorules_repos.yml") if File.exists?("/tmp/test_gitorules_repos.yml")
      end

      it "discovers repos via API when repos not set" do
        config_yaml = "org: testorg\nrules:\n  default_branch:\n    merge: only\n"
        File.write("/tmp/test_gitorules_discover.yml", config_yaml)

        WebMock.stub(:get, "https://api.github.com/orgs/testorg/repos?per_page=100&type=owner")
          .to_return(body: %([{"name": "repo1"}, {"name": "repo2"}]),
            headers: {"Content-Type" => "application/json"})

        loader = ConfigLoader.new("/tmp/test_gitorules_discover.yml", token)
        names = loader.repo_names
        names.should eq ["testorg/repo1", "testorg/repo2"]
      ensure
        File.delete("/tmp/test_gitorules_discover.yml") if File.exists?("/tmp/test_gitorules_discover.yml")
        WebMock.reset
      end

      it "raises when neither repos nor org is set" do
        config_yaml = "rules:\n  default_branch:\n    merge: only\n"
        File.write("/tmp/test_gitorules_none.yml", config_yaml)

        expect_raises(Exception, "No repos or org in config") do
          loader = ConfigLoader.new("/tmp/test_gitorules_none.yml", token)
          loader.repo_names
        end
      ensure
        File.delete("/tmp/test_gitorules_none.yml") if File.exists?("/tmp/test_gitorules_none.yml")
      end
    end
  end
end
