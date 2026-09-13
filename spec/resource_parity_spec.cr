require "./spec_helper"

module Gitorules
  describe "diff text vs JSON parity" do
    token = "test-token"
    repo = "unurgunite/docscribe"

    client = GitHubClient.new(token)
    config = Config.from_yaml("org: unurgunite\nrepos:\n  - docscribe\nrules:\n  default_branch:\n    merge: only\n    checks: [\"check / check\"]\n  release:\n    pattern: v*\n    squash: only\n")
    engine = Engine.new(client, config)

    before_each do
      WebMock.reset
    end

    it "create in text matches create in JSON" do
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
        .to_return(body: "[]")

      text_io = IO::Memory.new
      engine.diff([repo], io: text_io)
      text = text_io.to_s
      text.should contain("+ Create ruleset 'master'")

      WebMock.reset
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
        .to_return(body: "[]")

      json_io = IO::Memory.new
      engine.diff_json([repo], json_io)
      changes = JSON.parse(json_io.to_s).as_a[0]["changes"].as_a
      master = changes.select { |c| c["name"].to_s == "master" }
      master.size.should eq(1)
      master[0]["action"].to_s.should eq("create")
    end

    it "update in text matches update in JSON" do
      list_body = %([{"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": []}])
      full_body = %({"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": [
        {"type": "deletion"},
        {"type": "non_fast_forward"},
        {"type": "pull_request", "parameters": {"allowed_merge_methods": ["squash"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}},
        {"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "lint"}], "strict_required_status_checks_policy": true}}
      ]})

      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
        .to_return(body: list_body)
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/1")
        .to_return(body: full_body)

      text_io = IO::Memory.new
      engine.diff([repo], io: text_io)
      text_io.to_s.should contain("~ Update ruleset 'master'")

      WebMock.reset
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
        .to_return(body: list_body)
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/1")
        .to_return(body: full_body)

      json_io = IO::Memory.new
      engine.diff_json([repo], json_io)
      changes = JSON.parse(json_io.to_s).as_a[0]["changes"].as_a
      master = changes.select { |c| c["name"].to_s == "master" }
      master.size.should eq(1)
      master[0]["action"].to_s.should eq("update")
      master[0]["changes"].as_a.should_not be_empty
    end

    it "unchanged in text matches unchanged in JSON" do
      list_body = %([{"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": []}])
      full_body = %({"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": [
        {"type": "deletion"},
        {"type": "non_fast_forward"},
        {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}},
        {"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "check / check"}], "strict_required_status_checks_policy": true}}
      ]})

      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
        .to_return(body: list_body)
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/1")
        .to_return(body: full_body)

      text_io = IO::Memory.new
      engine.diff([repo], io: text_io)
      text_io.to_s.should contain("master:   no changes")

      WebMock.reset
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
        .to_return(body: list_body)
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/1")
        .to_return(body: full_body)

      json_io = IO::Memory.new
      engine.diff_json([repo], json_io)
      changes = JSON.parse(json_io.to_s).as_a[0]["changes"].as_a
      master = changes.select { |c| c["name"].to_s == "master" }
      master.size.should eq(1)
      master[0]["action"].to_s.should eq("unchanged")
    end

    it "orphan in text matches orphan in JSON" do
      list_body = %([{"id": 10, "name": "master", "enforcement": "active", "target": "branch", "rules": []}, {"id": 11, "name": "Deprecated", "enforcement": "active", "target": "branch", "rules": []}])
      full_body = %({"id": 10, "name": "master", "enforcement": "active", "target": "branch", "rules": [
        {"type": "deletion"},
        {"type": "non_fast_forward"},
        {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}},
        {"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "check / check"}], "strict_required_status_checks_policy": true}}
      ]})

      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
        .to_return(body: list_body)
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/10")
        .to_return(body: full_body)

      text_io = IO::Memory.new
      engine.diff([repo], io: text_io)
      text_io.to_s.should contain("Orphan ruleset 'Deprecated'")

      WebMock.reset
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
        .to_return(body: list_body)
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/10")
        .to_return(body: full_body)

      json_io = IO::Memory.new
      engine.diff_json([repo], json_io)
      changes = JSON.parse(json_io.to_s).as_a[0]["changes"].as_a
      orphans = changes.select { |c| c["action"].to_s == "orphan" }
      orphans.size.should eq(1)
      orphans[0]["name"].to_s.should eq("Deprecated")
    end
  end
end
