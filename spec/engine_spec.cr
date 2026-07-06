require "./spec_helper"

module Gitorules
  describe Engine do
    token = "test-token"
    repo = "unurgunite/docscribe"

    client = GitHubClient.new(token)
    config = Config.from_yaml("org: unurgunite\nrepos:\n  - docscribe\nrules:\n  default_branch:\n    merge: only\n    checks: [\"check / check\"]\n  release:\n    pattern: v*\n    squash: only\n")
    engine = Engine.new(client, config)

    describe "#status" do
      before_each do
        WebMock.reset
      end

      it "prints OK for fully configured repo" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %([{"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": []}]))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/1")
          .to_return(body: %({"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": [
            {"type": "deletion"},
            {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}},
            {"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "check / check"}], "strict_required_status_checks_policy": true}}
          ]}))

        io = IO::Memory.new
        engine.status([repo], io)
        io.to_s.should contain("✓ merge +checks")
      end

      it "warns for missing checks" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %([{"id": 2, "name": "master", "enforcement": "active", "target": "branch", "rules": []}]))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/2")
          .to_return(body: %({"id": 2, "name": "master", "enforcement": "active", "target": "branch", "rules": [
            {"type": "deletion"},
            {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}}
          ]}))

        io = IO::Memory.new
        engine.status([repo], io)
        io.to_s.should contain("✓ merge -checks")
      end

      it "handles API errors gracefully" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/unknown/rulesets")
          .to_return(status: 404)

        io = IO::Memory.new
        engine.status(["unurgunite/unknown"], io)
        io.to_s.should contain("Not found")
      end
    end

    describe "#diff" do
      before_each do
        WebMock.reset
      end

      it "shows create for missing rulesets" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")

        io = IO::Memory.new
        engine.diff([repo], io)
        io.to_s.should contain("+ Create")
        io.to_s.should contain("master")
        io.to_s.should contain("Release branches")
      end

      it "shows no changes when rulesets match" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %([{"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": []}]))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/1")
          .to_return(body: %({"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": [
            {"type": "deletion"},
            {"type": "non_fast_forward"},
            {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}},
            {"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "check / check"}], "strict_required_status_checks_policy": true}}
          ]}))

        io = IO::Memory.new
        engine.diff([repo], io)
        io.to_s.should contain("no changes")
      end

      it "shows update when rules differ" do
        # List has existing ruleset, but full fetch shows different params
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %([{"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": []}]))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/1")
          .to_return(body: %({"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": [
            {"type": "deletion"},
            {"type": "non_fast_forward"},
            {"type": "pull_request", "parameters": {"allowed_merge_methods": ["squash"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}},
            {"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "lint"}], "strict_required_status_checks_policy": true}}
          ]}))

        io = IO::Memory.new
        engine.diff([repo], io)
        io.to_s.should contain("~ Update")
        io.to_s.should contain("allowed_merge_methods")
      end

      it "handles API errors gracefully" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/unknown/rulesets")
          .to_return(status: 404)

        io = IO::Memory.new
        engine.diff(["unurgunite/unknown"], io)
        io.to_s.should contain("Error: Not found")
      end
    end

    describe "#apply" do
      before_each do
        WebMock.reset
      end

      it "creates both master and release rulesets" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")

        WebMock.stub(:post, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %({"id": 1, "name": "test", "enforcement": "active", "target": "branch", "rules": []}))

        io = IO::Memory.new
        engine.apply([repo], dry_run: false, io: io)
        io.to_s.should contain("Created ruleset 'master'")
        io.to_s.should contain("Created ruleset 'Release branches — squash only'")
      end

      it "updates existing rulesets" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %([{"id": 1, "name": "Master - merge commits only", "enforcement": "active", "target": "branch", "rules": []}, {"id": 2, "name": "Release branches - squash only", "enforcement": "active", "target": "branch", "rules": []}]))

        WebMock.stub(:put, "https://api.github.com/repos/unurgunite/docscribe/rulesets/1")
          .to_return(body: %({"id": 1, "name": "test", "enforcement": "active", "target": "branch", "rules": []}))
        WebMock.stub(:put, "https://api.github.com/repos/unurgunite/docscribe/rulesets/2")
          .to_return(body: %({"id": 2, "name": "test", "enforcement": "active", "target": "branch", "rules": []}))

        io = IO::Memory.new
        engine.apply([repo], io: io)
        io.to_s.should contain("Updated ruleset 'master'")
        io.to_s.should contain("Updated ruleset 'Release branches — squash only'")
      end

      it "dry-run prints intentions without modification" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")

        io = IO::Memory.new
        engine.apply([repo], dry_run: true, io: io)
        io.to_s.should contain("Would create ruleset 'master'")
        io.to_s.should contain("Would create ruleset 'Release branches — squash only'")
      end

      it "uses pattern from config for release branch conditions" do
        custom_config = Config.from_yaml("org: unurgunite\nrepos:\n  - docscribe\nrules:\n  default_branch:\n    merge: only\n  release:\n    pattern: release/*\n    squash: only\n")
        custom_engine = Engine.new(client, custom_config)

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")

        WebMock.stub(:post, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %({"id": 1, "name": "test", "enforcement": "active", "target": "branch", "rules": []}))

        io = IO::Memory.new
        custom_engine.apply([repo], io: io)
        io.to_s.should contain("Created ruleset 'Release branches — squash only'")
      end
    end
  end
end
