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
        io.to_s.should contain("✓ merge")
        io.to_s.should contain("✓ active")
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
        io.to_s.should contain("✗ missing")
      end

      it "handles API errors gracefully" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/unknown/rulesets")
          .to_return(status: 404)

        io = IO::Memory.new
        engine.status(["unurgunite/unknown"], io)
        io.to_s.should contain("Not found")
      end
    end
  end
end
