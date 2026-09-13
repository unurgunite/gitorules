require "./spec_helper"

module Gitorules
  describe "unified JSON contract" do
    token = "test-token"
    client = GitHubClient.new(token)
    config = Config.from_yaml("org: unurgunite\nrepos:\n  - docscribe\nrules:\n  default_branch:\n    merge: only\n    checks: [\"check / check\"]\n")
    engine = Engine.new(client, config)

    full_master_ok = %({"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": [
      {"type": "deletion"},
      {"type": "non_fast_forward"},
      {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}},
      {"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "check / check"}], "strict_required_status_checks_policy": true}}
    ]})

    full_master_wrong = %({"id": 2, "name": "master", "enforcement": "active", "target": "branch", "rules": [
      {"type": "deletion"},
      {"type": "non_fast_forward"},
      {"type": "pull_request", "parameters": {"allowed_merge_methods": ["squash"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}},
      {"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "lint"}], "strict_required_status_checks_policy": true}}
    ]})

    before_each do
      WebMock.reset
    end

    it "status entries expose unified resource/action/changes" do
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/ok/rulesets")
        .to_return(body: %([{"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": []}]))
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/ok/rulesets/1")
        .to_return(body: full_master_ok)
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/missing/rulesets")
        .to_return(body: "[]")
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/broken/rulesets")
        .to_return(status: 404)

      io = IO::Memory.new
      engine.status_json(["unurgunite/ok", "unurgunite/missing", "unurgunite/broken"], io)
      arr = JSON.parse(io.to_s).as_a
      arr.size.should eq 3
      arr.map(&.["repo"].to_s).should eq ["unurgunite/ok", "unurgunite/missing", "unurgunite/broken"]

      ok_type = arr[0]["types"]["default_branch"]
      ok_type["exists"].should be_true
      ok_type["resource"].to_s.should eq "master"
      ok_type["action"].to_s.should eq "unchanged"
      ok_type["changes"].as_a.should be_empty
      JsonEntry.valid_action?(ok_type["action"].to_s).should be_true

      missing_type = arr[1]["types"]["default_branch"]
      missing_type["exists"].should be_false
      missing_type["resource"].to_s.should eq "master"
      missing_type["action"].to_s.should eq "create"
      missing_type["changes"].as_a.should be_empty

      arr[2]["error"].to_s.should contain("Not found")
      arr[2]["action"].to_s.should eq "error"
      arr[2]["resource"].to_s.should eq ""
      arr[2]["changes"].as_a.should be_empty
    end

    it "status update action carries changes descriptions" do
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/stale/rulesets")
        .to_return(body: %([{"id": 2, "name": "master", "enforcement": "active", "target": "branch", "rules": []}]))
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/stale/rulesets/2")
        .to_return(body: full_master_wrong)

      io = IO::Memory.new
      engine.status_json(["unurgunite/stale"], io)
      entry = JSON.parse(io.to_s).as_a[0]["types"]["default_branch"]
      entry["action"].to_s.should eq "update"
      entry["changes"].as_a.should_not be_empty
      entry["merge_method_ok"].should be_false
      entry["checks_ok"].should be_false
    end

    it "diff entries expose unified resource/action/changes" do
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/ok/rulesets")
        .to_return(body: %([{"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": []}]))
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/ok/rulesets/1")
        .to_return(body: full_master_ok)
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/missing/rulesets")
        .to_return(body: "[]")
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/orphaned/rulesets")
        .to_return(body: %([{"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": []}, {"id": 9, "name": "Deprecated", "enforcement": "active", "target": "branch", "rules": []}]))
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/orphaned/rulesets/1")
        .to_return(body: full_master_ok)

      io = IO::Memory.new
      engine.diff_json(["unurgunite/ok", "unurgunite/missing", "unurgunite/orphaned"], io)
      arr = JSON.parse(io.to_s).as_a
      arr.size.should eq 3

      ok_changes = arr[0]["changes"].as_a
      ok_changes.size.should eq 1
      ok_changes[0]["action"].to_s.should eq "unchanged"
      ok_changes[0]["resource"].to_s.should eq "master"
      ok_changes[0]["name"].to_s.should eq "master"
      ok_changes[0]["changes"].as_a.should be_empty

      missing_changes = arr[1]["changes"].as_a
      missing_changes.any? { |c| c["action"].to_s == "create" }.should be_true
      missing_changes.each do |c|
        JsonEntry.valid_action?(c["action"].to_s).should be_true
        c["resource"].to_s.should_not be_empty
        c["changes"].as_a.should be_a(Array(JSON::Any))
      end

      orphans = arr[2]["changes"].as_a.select { |c| c["action"].to_s == "orphan" }
      orphans.size.should eq 1
      orphans[0]["resource"].to_s.should eq "Deprecated"
      orphans[0]["changes"].as_a.should be_empty
    end

    it "diff error entries carry unified error action" do
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/broken/rulesets")
        .to_return(status: 404)

      io = IO::Memory.new
      engine.diff_json(["unurgunite/broken"], io)
      entry = JSON.parse(io.to_s).as_a[0]
      entry["error"].to_s.should contain("Not found")
      entry["action"].to_s.should eq "error"
      entry["resource"].to_s.should eq ""
    end

    it "apply entries expose unified resource/action/changes" do
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/missing/rulesets")
        .to_return(body: "[]")
      WebMock.stub(:post, "https://api.github.com/repos/unurgunite/missing/rulesets")
        .to_return(body: %({"id": 1, "name": "test", "enforcement": "active", "target": "branch", "rules": []}))
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/existing/rulesets")
        .to_return(body: %([{"id": 7, "name": "master", "enforcement": "active", "target": "branch", "rules": []}]))
      WebMock.stub(:put, "https://api.github.com/repos/unurgunite/existing/rulesets/7")
        .to_return(body: %({"id": 7, "name": "test", "enforcement": "active", "target": "branch", "rules": []}))

      io = IO::Memory.new
      engine.apply_json(["unurgunite/missing", "unurgunite/existing"], io: io)
      arr = JSON.parse(io.to_s).as_a
      arr.map(&.["repo"].to_s).should eq ["unurgunite/missing", "unurgunite/existing"]

      creates = arr[0]["results"].as_a
      creates[0]["action"].to_s.should eq "create"
      creates[0]["resource"].to_s.should eq creates[0]["name"].to_s
      creates[0]["changes"].as_a.should be_empty

      updates = arr[1]["results"].as_a
      updates[0]["action"].to_s.should eq "update"
      updates[0]["resource"].to_s.should eq updates[0]["name"].to_s
      updates[0]["changes"].as_a.should be_empty
    end

    it "skip action for repos without configured rules" do
      multi = Config.from_yaml("orgs:\n  unurgunite:\n    repos:\n      - docscribe\n    rules:\n      default_branch:\n        merge: only\n")
      multi_engine = Engine.new(client, multi)

      WebMock.stub(:get, "https://api.github.com/repos/other/repo/rulesets")
        .to_return(body: "[]")

      io = IO::Memory.new
      multi_engine.diff_json(["other/repo"], io)
      changes = JSON.parse(io.to_s).as_a[0]["changes"].as_a
      changes.any? { |c| c["action"].to_s == "skip" }.should be_true

      io2 = IO::Memory.new
      multi_engine.apply_json(["other/repo"], io: io2)
      results = JSON.parse(io2.to_s).as_a[0]["results"].as_a
      results.any? { |r| r["action"].to_s == "skip" }.should be_true

      WebMock.stub(:get, "https://api.github.com/repos/other/repo2/rulesets")
        .to_return(body: %([{"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": []}]))
      WebMock.stub(:get, "https://api.github.com/repos/other/repo2/rulesets/1")
        .to_return(body: full_master_ok)
      io3 = IO::Memory.new
      multi_engine.status_json(["other/repo2"], io3)
      entry = JSON.parse(io3.to_s).as_a[0]["types"]["default_branch"]
      entry["action"].to_s.should eq "skip"
    end

    it "all emitted actions belong to the unified vocabulary" do
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/a/rulesets")
        .to_return(body: "[]")
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/b/rulesets")
        .to_return(status: 500, body: "boom")

      io = IO::Memory.new
      engine.diff_json(["unurgunite/a", "unurgunite/b"], io)
      arr = JSON.parse(io.to_s).as_a
      arr[0]["changes"].as_a.each do |c|
        JsonEntry.valid_action?(c["action"].to_s).should be_true
      end
      JsonEntry.valid_action?(arr[1]["action"].to_s).should be_true
    end
  end
end
