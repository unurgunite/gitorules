require "./spec_helper"

module Gitorules
  describe CLI do
    describe ".run" do
      it "prints version and exits 0 on --version" do
        CLI.run(["--version"]).should eq(0)
      end

      it "prints help and exits 0 on --help" do
        CLI.run(["--help"]).should eq(0)
      end

      it "prints help and exits 0 on -h" do
        CLI.run(["-h"]).should eq(0)
      end

      it "returns 2 when GITHUB_TOKEN not set and no --token" do
        CLI.run(["status"]).should eq(2)
      end

      it "returns 2 when config file not found" do
        CLI.run(["--token", "test", "--config", File.join(Dir.tempdir, "nonexistent.yml"), "status"]).should eq(2)
      end

      it "prints help and exits 0 when no command given" do
        CLI.run([] of String).should eq(0)
      end

      it "prints help and exits 0 with --token but no command" do
        CLI.run(["--token", "test"]).should eq(0)
      end
    end

    describe "exit codes" do
      repo = "unurgunite/test-repo"
      config_path = File.join(Dir.tempdir, "cli-exit-codes.yml")
      config_yaml = <<-YAML
        org: unurgunite
        repos:
          - test-repo
        rules:
          default_branch:
            merge: only
            checks: ["check / check"]
        YAML

      before_each do
        WebMock.reset
        File.write(config_path, config_yaml)
      end

      after_each do
        File.delete(config_path) if File.exists?(config_path)
      end

      it "returns 0 for status" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/test-repo/rulesets")
          .to_return(body: "[]")

        CLI.run(["--token", "test", "--config", config_path, "status", "--repo", repo]).should eq(0)
      end

      it "returns 0 for diff with no changes" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/test-repo/rulesets")
          .to_return(body: %([{"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": []}]))
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/test-repo/rulesets/1")
          .to_return(body: %({"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": [
            {"type": "deletion"},
            {"type": "non_fast_forward"},
            {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}},
            {"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "check / check"}], "strict_required_status_checks_policy": true}}
          ]}))

        CLI.run(["--token", "test", "--config", config_path, "diff", "--repo", repo]).should eq(0)
      end

      it "returns 1 for diff with changes" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/test-repo/rulesets")
          .to_return(body: "[]")

        CLI.run(["--token", "test", "--config", config_path, "diff", "--repo", repo]).should eq(1)
      end

      it "returns 0 for apply with no changes" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/test-repo/rulesets")
          .to_return(body: %([{"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": []}]))
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/test-repo/rulesets/1")
          .to_return(body: %({"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": [
            {"type": "deletion"},
            {"type": "non_fast_forward"},
            {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}},
            {"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "check / check"}], "strict_required_status_checks_policy": true}}
          ]}))

        CLI.run(["--token", "test", "--config", config_path, "apply", "--repo", repo, "--yes"]).should eq(0)
      end

      it "returns 1 for apply with --yes flag" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/test-repo/rulesets")
          .to_return(body: "[]")
        WebMock.stub(:post, "https://api.github.com/repos/unurgunite/test-repo/rulesets")
          .to_return(body: %({"id": 1, "name": "test", "enforcement": "active", "target": "branch", "rules": []}))

        CLI.run(["--token", "test", "--config", config_path, "apply", "--repo", repo, "--yes"]).should eq(1)
      end

      it "returns 1 for apply with confirmation accepted" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/test-repo/rulesets")
          .to_return(body: "[]")
        WebMock.stub(:post, "https://api.github.com/repos/unurgunite/test-repo/rulesets")
          .to_return(body: %({"id": 1, "name": "test", "enforcement": "active", "target": "branch", "rules": []}))

        input_io = IO::Memory.new("y\n")
        CLI.run(["--token", "test", "--config", config_path, "apply", "--repo", repo], input_io: input_io).should eq(1)
      end

      it "returns 1 for apply with confirmation declined" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/test-repo/rulesets")
          .to_return(body: "[]")

        input_io = IO::Memory.new("n\n")
        CLI.run(["--token", "test", "--config", config_path, "apply", "--repo", repo], input_io: input_io).should eq(1)
      end

      it "returns 1 for apply --dry-run with --yes (changes detected)" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/test-repo/rulesets")
          .to_return(body: "[]")

        CLI.run(["--token", "test", "--config", config_path, "apply", "--repo", repo, "--dry-run", "--yes"]).should eq(1)
      end

      it "warns about --dry-run ignored with status" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/test-repo/rulesets")
          .to_return(body: "[]")

        IO::Memory.new
        status = CLI.run(["--token", "test", "--config", config_path, "status", "--repo", repo, "--dry-run"])
        status.should eq(0)
      end

      it "warns about --diff ignored with diff" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/test-repo/rulesets")
          .to_return(body: %([{"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": []}]))
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/test-repo/rulesets/1")
          .to_return(body: %({"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": [
            {"type": "deletion"},
            {"type": "non_fast_forward"},
            {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}},
            {"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "check / check"}], "strict_required_status_checks_policy": true}}
          ]}))

        status = CLI.run(["--token", "test", "--config", config_path, "diff", "--repo", repo, "--diff"])
        status.should eq(0)
      end
    end
  end
end
