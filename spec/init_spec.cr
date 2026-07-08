require "./spec_helper"

module Gitorules
  describe ConfigGenerator do
    token = "test-token"
    repo = "unurgunite/docscribe"

    before_each do
      WebMock.reset
    end

    describe "#generate" do
      it "generates config for repo with master + release rulesets" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %([{"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": []}, {"id": 2, "name": "Release branches — squash only", "enforcement": "active", "target": "branch", "rules": []}]))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/1")
          .to_return(body: %({"id": 1, "name": "master", "enforcement": "active", "target": "branch", "conditions": {"ref_name": {"include": ["refs/heads/master"], "exclude": []}}, "rules": [
            {"type": "deletion"},
            {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}},
            {"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "check / check"}], "strict_required_status_checks_policy": true}}
          ]}))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/2")
          .to_return(body: %({"id": 2, "name": "Release branches — squash only", "enforcement": "active", "target": "branch", "conditions": {"ref_name": {"include": ["refs/heads/v*"], "exclude": []}}, "rules": [
            {"type": "deletion"},
            {"type": "pull_request", "parameters": {"allowed_merge_methods": ["squash"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}}
          ]}))

        client = GitHubClient.new(token)
        generator = ConfigGenerator.new(client)
        io = IO::Memory.new
        generator.generate([repo], io)
        output = io.to_s

        output.should contain("org: unurgunite")
        output.should contain("repos:")
        output.should contain("default_branch:")
        output.should contain("merge: only")
        output.should contain("release:")
        output.should contain("squash: only")
      end

      it "classifies system/* pattern correctly" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %([{"id": 3, "name": "System branches", "enforcement": "active", "target": "branch", "rules": []}]))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/3")
          .to_return(body: %({"id": 3, "name": "System branches", "enforcement": "active", "target": "branch", "conditions": {"ref_name": {"include": ["refs/heads/system/*"], "exclude": []}}, "rules": [
            {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}}
          ]}))

        client = GitHubClient.new(token)
        generator = ConfigGenerator.new(client)
        io = IO::Memory.new
        generator.generate([repo], io)
        output = io.to_s

        output.should contain("system:")
      end

      it "handles API error for a repo gracefully" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(status: 404)

        client = GitHubClient.new(token)
        generator = ConfigGenerator.new(client)
        io = IO::Memory.new
        generator.generate([repo], io)
        output = io.to_s

        output.should contain("org: unurgunite")
        output.should contain("repos:")
        output.should_not contain("rules:")
      end

      it "logs warning to STDERR when get_ruleset fails" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %([{"id": 99, "name": "broken", "enforcement": "active", "target": "branch", "rules": []}]))
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/99")
          .to_return(status: 500)

        client = GitHubClient.new(token)
        generator = ConfigGenerator.new(client)
        io = IO::Memory.new
        generator.generate([repo], io)
        output = io.to_s

        output.should contain("WARNING: 1 ruleset(s) skipped")
      end

      it "includes skipped count in YAML comment when errors occur" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %([{"id": 99, "name": "broken", "enforcement": "active", "target": "branch", "rules": []}]))
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/99")
          .to_return(status: 500)

        client = GitHubClient.new(token)
        generator = ConfigGenerator.new(client)
        io = IO::Memory.new
        generator.generate([repo], io)
        output = io.to_s

        output.should contain("# WARNING: 1 ruleset(s) skipped")
      end

      it "handles repo with empty rulesets" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")

        client = GitHubClient.new(token)
        generator = ConfigGenerator.new(client)
        io = IO::Memory.new
        generator.generate([repo], io)
        output = io.to_s

        output.should contain("org: unurgunite")
        output.should_not contain("rules:")
      end

      it "merges configs from multiple repos" do
        repo_a = "unurgunite/repo-a"
        repo_b = "unurgunite/repo-b"

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/repo-a/rulesets")
          .to_return(body: %([{"id": 10, "name": "master", "enforcement": "active", "target": "branch", "rules": []}]))
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/repo-b/rulesets")
          .to_return(body: %([{"id": 11, "name": "master", "enforcement": "active", "target": "branch", "rules": []}]))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/repo-a/rulesets/10")
          .to_return(body: %({"id": 10, "name": "master", "enforcement": "active", "target": "branch", "conditions": {"ref_name": {"include": ["refs/heads/master"], "exclude": []}}, "rules": [
            {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}}
          ]}))
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/repo-b/rulesets/11")
          .to_return(body: %({"id": 11, "name": "master", "enforcement": "active", "target": "branch", "conditions": {"ref_name": {"include": ["refs/heads/master"], "exclude": []}}, "rules": [
            {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}},
            {"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "check / check"}], "strict_required_status_checks_policy": true}}
          ]}))

        client = GitHubClient.new(token)
        generator = ConfigGenerator.new(client)
        io = IO::Memory.new
        generator.generate([repo_a, repo_b], io)
        output = io.to_s

        output.should contain("merge: only")
        output.should contain("check / check")
      end
    end
  end
end
