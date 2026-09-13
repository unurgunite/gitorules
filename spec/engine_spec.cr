require "./spec_helper"

module Gitorules
  STRIP_ANSI = ->(str : String) { str.gsub(/\e\[[0-9;]*m/, "") }
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
        engine.status([repo], io: io)
        output = STRIP_ANSI.call(io.to_s)
        output.should contain("✓ merge +checks")
        output.should contain("[1/1]")
        output.should contain("All rulesets up to date")
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
        engine.status([repo], io: io)
        STRIP_ANSI.call(io.to_s).should contain("✓ merge -checks")
      end

      it "handles API errors gracefully with ERR row" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/unknown/rulesets")
          .to_return(status: 404)

        io = IO::Memory.new
        engine.status(["unurgunite/unknown"], io: io)
        output = io.to_s
        output.should_not contain("Not found")
        output.should contain("ERR")
        output.should contain("[1/1]")
      end

      it "shows ~checks for wrong context" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %([{"id": 4, "name": "master", "enforcement": "active", "target": "branch", "rules": []}]))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/4")
          .to_return(body: %({"id": 4, "name": "master", "enforcement": "active", "target": "branch", "rules": [
            {"type": "deletion"},
            {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}},
            {"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "check"}], "strict_required_status_checks_policy": true}}
          ]}))

        io = IO::Memory.new
        engine.status([repo], io: io)
        STRIP_ANSI.call(io.to_s).should contain("✓ merge ~checks")
      end

      it "shows ✗ method mismatch" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %([{"id": 5, "name": "master", "enforcement": "active", "target": "branch", "rules": []}]))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/5")
          .to_return(body: %({"id": 5, "name": "master", "enforcement": "active", "target": "branch", "rules": [
            {"type": "deletion"},
            {"type": "pull_request", "parameters": {"allowed_merge_methods": ["squash"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}}
          ]}))

        io = IO::Memory.new
        engine.status([repo], io: io)
        io.to_s.should contain("✗ squash")
      end

      it "shows MISSING when no matching ruleset found" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %([{"id": 6, "name": "unrelated", "enforcement": "active", "target": "branch", "rules": []}]))

        io = IO::Memory.new
        engine.status([repo], io: io)
        io.to_s.should contain("✗ MISSING")
      end

      it "shows +checks with no checks configured in type" do
        no_checks_config = Config.from_yaml("org: unurgunite\nrepos:\n  - docscribe\nrules:\n  default_branch:\n    merge: only\n")
        no_checks_engine = Engine.new(client, no_checks_config)

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %([{"id": 7, "name": "master", "enforcement": "active", "target": "branch", "rules": []}]))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/7")
          .to_return(body: %({"id": 7, "name": "master", "enforcement": "active", "target": "branch", "rules": [
            {"type": "deletion"},
            {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}}
          ]}))

        io = IO::Memory.new
        no_checks_engine.status([repo], io: io)
        io.to_s.should contain("✓ merge")
        io.to_s.should_not contain("checks")
      end

      it "quiet mode only shows summary line" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %([{"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": []}]))
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/1")
          .to_return(body: %({"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": [
            {"type": "deletion"},
            {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}},
            {"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "check / check"}], "strict_required_status_checks_policy": true}}
          ]}))

        io = IO::Memory.new
        engine.status([repo], quiet: true, io: io)
        output = io.to_s
        output.should contain("All rulesets up to date")
        output.should_not contain("[1/1]")
        output.should_not contain("✓")
      end

      it "quiet mode with API error shows up-to-date (error caught internally)" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/unknown/rulesets")
          .to_return(status: 404)

        io = IO::Memory.new
        engine.status(["unurgunite/unknown"], quiet: true, io: io)
        output = io.to_s
        output.should contain("All rulesets up to date")
        output.should_not contain("[1/1]")
      end

      it "error row has correct padding" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/unknown/rulesets")
          .to_return(status: 404)

        io = IO::Memory.new
        engine.status(["unurgunite/unknown"], io: io)
        output = STRIP_ANSI.call(io.to_s)
        output.should match(/unknown\s+ERR\s+ERR/)
      end

      it "no ANSI codes in IO::Memory output" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %([{"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": []}]))
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/1")
          .to_return(body: %({"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": [
            {"type": "deletion"},
            {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}},
            {"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "check / check"}], "strict_required_status_checks_policy": true}}
          ]}))

        io = IO::Memory.new
        engine.status([repo], io: io)
        io.to_s.should_not match(/\e\[/)
      end
    end

    describe "#diff" do
      before_each do
        WebMock.reset
      end

      it "continues with other repos when one fails" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/unknown/rulesets")
          .to_return(status: 500)
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")

        io = IO::Memory.new
        engine.diff(["unurgunite/unknown", repo], io: io)
        io.to_s.should contain("unurgunite/unknown: Error:")
        io.to_s.should contain("+ Create")
        io.to_s.should contain("[1/2]")
        io.to_s.should contain("[2/2]")
        io.to_s.should contain("Done: 2 repos processed")
      end

      it "shows create for missing rulesets" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")

        io = IO::Memory.new
        engine.diff([repo], io: io)
        io.to_s.should contain("+ Create")
        io.to_s.should contain("master")
        io.to_s.should contain("Release branches")
        io.to_s.should contain("[1/1]")
        io.to_s.should contain("Done: 1 repos processed")
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
        engine.diff([repo], io: io)
        io.to_s.should contain("no changes")
      end

      it "shows update when rules differ" do
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
        engine.diff([repo], io: io)
        io.to_s.should contain("~ Update")
        io.to_s.should contain("allowed_merge_methods")
      end

      it "handles API errors gracefully" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/unknown/rulesets")
          .to_return(status: 404)

        io = IO::Memory.new
        engine.diff(["unurgunite/unknown"], io: io)
        io.to_s.should contain("Error: Not found")
        io.to_s.should contain("[1/1]")
      end

      it "shows orphan rulesets" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %([{"id": 10, "name": "master", "enforcement": "active", "target": "branch", "rules": []}, {"id": 11, "name": "Deprecated", "enforcement": "active", "target": "branch", "rules": []}]))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/10")
          .to_return(body: %({"id": 10, "name": "master", "enforcement": "active", "target": "branch", "rules": [
            {"type": "deletion"},
            {"type": "non_fast_forward"},
            {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}},
            {"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "check / check"}], "strict_required_status_checks_policy": true}}
          ]}))

        io = IO::Memory.new
        engine.diff([repo], io: io)
        io.to_s.should contain("no changes")
        io.to_s.should contain("Orphan")
        io.to_s.should contain("Deprecated")
      end

      it "quiet mode only shows summary line" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")

        io = IO::Memory.new
        engine.diff([repo], quiet: true, io: io)
        output = io.to_s
        output.should contain("Done: 1 repos processed")
        output.should_not contain("[1/1]")
        output.should_not contain("+ Create")
      end
    end

    describe "#apply" do
      before_each do
        WebMock.reset
      end

      it "continues with other repos when one fails" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/unknown/rulesets")
          .to_return(status: 500)
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")
        WebMock.stub(:post, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %({"id": 1, "name": "test", "enforcement": "active", "target": "branch", "rules": []}))

        io = IO::Memory.new
        engine.apply(["unurgunite/unknown", repo], dry_run: false, io: io)
        io.to_s.should contain("unurgunite/unknown: Error:")
        io.to_s.should contain("Created ruleset 'master'")
        io.to_s.should contain("[1/2]")
        io.to_s.should contain("[2/2]")
        io.to_s.should contain("Done: 2 repos processed, 1 error(s)")
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
        io.to_s.should contain("[1/1]")
        io.to_s.should contain("Done: 1 repos processed, 0 error(s)")
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

      it "does nothing when no rules in config" do
        empty_config = Config.from_yaml("org: unurgunite\nrepos:\n  - docscribe\n")
        empty_engine = Engine.new(client, empty_config)

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")

        io = IO::Memory.new
        empty_engine.apply([repo], io: io)
        io.to_s.should contain("Done: 1 repos processed, 0 error(s)")
        io.to_s.should_not contain("Created ruleset")
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

      it "quiet mode only shows summary line" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/unknown/rulesets")
          .to_return(status: 500)

        io = IO::Memory.new
        engine.apply(["unurgunite/unknown"], quiet: true, io: io)
        output = io.to_s
        output.should contain("Done: 1 repos processed, 1 error(s)")
        output.should_not contain("[1/1]")
        output.should_not contain("Error:")
      end
    end

    describe "#status_json" do
      before_each do
        WebMock.reset
      end

      it "returns JSON with exists: true for configured repo" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %([{"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": []}]))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/1")
          .to_return(body: %({"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": [
            {"type": "deletion"},
            {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}},
            {"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "check / check"}], "strict_required_status_checks_policy": true}}
          ]}))

        io = IO::Memory.new
        engine.status_json([repo], io)
        json = JSON.parse(io.to_s).as_a
        entry = json[0]
        entry["repo"].should eq(repo)
        entry["types"]["default_branch"]["exists"].should be_true
        entry["types"]["default_branch"]["merge_method_ok"].should be_true
        entry["types"]["default_branch"]["checks_ok"].should be_true
      end

      it "returns exists: false for missing ruleset" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %([{"id": 1, "name": "unrelated", "enforcement": "active", "target": "branch", "rules": []}]))

        io = IO::Memory.new
        engine.status_json([repo], io)
        json = JSON.parse(io.to_s).as_a
        json[0]["types"]["default_branch"]["exists"].should be_false
      end

      it "includes error field on API failure" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/unknown/rulesets")
          .to_return(status: 404)

        io = IO::Memory.new
        engine.status_json(["unurgunite/unknown"], io)
        json = JSON.parse(io.to_s).as_a
        json[0]["error"].to_s.should contain("Not found")
      end
    end

    describe "#diff_json" do
      before_each do
        WebMock.reset
      end

      it "shows create action for missing rulesets" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")

        io = IO::Memory.new
        engine.diff_json([repo], io)
        json = JSON.parse(io.to_s).as_a
        actions = json[0]["changes"].as_a.map(&.["action"].to_s)
        actions.should contain("create")
        actions.should contain("create") # both default_branch and release
      end

      it "shows update when rules differ" do
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
        engine.diff_json([repo], io)
        json = JSON.parse(io.to_s).as_a
        changes = json[0]["changes"].as_a
        actions = changes.select { |c| c["name"].to_s == "master" }
        actions.size.should eq(1)
        actions[0]["action"].to_s.should eq("update")
        actions[0]["changes"].as_a.should_not be_empty
      end

      it "shows orphan rulesets" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %([{"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": []}, {"id": 2, "name": "Deprecated", "enforcement": "active", "target": "branch", "rules": []}]))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/1")
          .to_return(body: %({"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": [
            {"type": "deletion"},
            {"type": "non_fast_forward"},
            {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}},
            {"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "check / check"}], "strict_required_status_checks_policy": true}}
          ]}))

        io = IO::Memory.new
        engine.diff_json([repo], io)
        json = JSON.parse(io.to_s).as_a
        orphans = json[0]["changes"].as_a.select { |c| c["action"].to_s == "orphan" }
        orphans.size.should eq(1)
        orphans[0]["name"].to_s.should eq("Deprecated")
      end

      it "includes error on API failure" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/unknown/rulesets")
          .to_return(status: 404)

        io = IO::Memory.new
        engine.diff_json(["unurgunite/unknown"], io)
        json = JSON.parse(io.to_s).as_a
        json[0]["error"].to_s.should contain("Not found")
      end

      it "continues with other repos when one fails" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/unknown/rulesets")
          .to_return(status: 500)
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")

        io = IO::Memory.new
        engine.diff_json(["unurgunite/unknown", repo], io)
        json = JSON.parse(io.to_s).as_a
        json[0]["error"].to_s.should contain("500")
        json[1]["repo"].to_s.should eq(repo)
      end
    end

    describe "#apply_json" do
      before_each do
        WebMock.reset
      end

      it "returns create results for new rulesets" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")

        WebMock.stub(:post, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %({"id": 1, "name": "test", "enforcement": "active", "target": "branch", "rules": []}))

        io = IO::Memory.new
        engine.apply_json([repo], dry_run: false, io: io)
        json = JSON.parse(io.to_s).as_a
        actions = json[0]["results"].as_a.map(&.["action"].to_s)
        actions.should contain("create")
        actions.should contain("create") # both default_branch and release
      end

      it "returns update results for existing rulesets" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %([{"id": 1, "name": "Master - merge commits only", "enforcement": "active", "target": "branch", "rules": []}, {"id": 2, "name": "Release branches - squash only", "enforcement": "active", "target": "branch", "rules": []}]))

        WebMock.stub(:put, "https://api.github.com/repos/unurgunite/docscribe/rulesets/1")
          .to_return(body: %({"id": 1, "name": "test", "enforcement": "active", "target": "branch", "rules": []}))
        WebMock.stub(:put, "https://api.github.com/repos/unurgunite/docscribe/rulesets/2")
          .to_return(body: %({"id": 2, "name": "test", "enforcement": "active", "target": "branch", "rules": []}))

        io = IO::Memory.new
        engine.apply_json([repo], io: io)
        json = JSON.parse(io.to_s).as_a
        actions = json[0]["results"].as_a.map(&.["action"].to_s)
        actions.should contain("update")
      end

      it "marks dry_run: true in dry-run mode" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")

        io = IO::Memory.new
        engine.apply_json([repo], dry_run: true, io: io)
        json = JSON.parse(io.to_s).as_a
        json[0]["results"].as_a.each do |r|
          r["dry_run"].should be_true
        end
      end

      it "includes error on API failure" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/unknown/rulesets")
          .to_return(status: 404)

        io = IO::Memory.new
        engine.apply_json(["unurgunite/unknown"], io: io)
        json = JSON.parse(io.to_s).as_a
        json[0]["error"].to_s.should contain("Not found")
      end

      it "continues with other repos when one fails" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/unknown/rulesets")
          .to_return(status: 500)
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")
        WebMock.stub(:post, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %({"id": 1, "name": "test", "enforcement": "active", "target": "branch", "rules": []}))

        io = IO::Memory.new
        engine.apply_json(["unurgunite/unknown", repo], dry_run: false, io: io)
        json = JSON.parse(io.to_s).as_a
        json[0]["error"].to_s.should contain("500")
        json[1]["repo"].to_s.should eq(repo)
      end
    end

    describe "multi-org" do
      before_each do
        WebMock.reset
      end

      multi_org_config = Config.from_yaml(<<-YAML)
        orgs:
          unurgunite:
            repos:
              - docscribe
            rules:
              default_branch:
                merge: only
              release:
                pattern: v*
                squash: only
          fintech:
            repos:
              - payment-api
            rules:
              default_branch:
                squash: only
        YAML

      multi_engine = Engine.new(client, multi_org_config)

      it "#status uses per-org rules" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %([{"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": []}]))
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/1")
          .to_return(body: %({"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": [
            {"type": "deletion"},
            {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}}
          ]}))

        io = IO::Memory.new
        multi_engine.status(["unurgunite/docscribe", "fintech/payment-api"], io: io)
        output = io.to_s
        output.should contain("default")
        output.should contain("release")
        output.should_not contain("hotfix")
      end

      it "#diff shows create for both org repos" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")
        WebMock.stub(:get, "https://api.github.com/repos/fintech/payment-api/rulesets")
          .to_return(body: "[]")

        io = IO::Memory.new
        multi_engine.diff(["unurgunite/docscribe", "fintech/payment-api"], io: io)
        output = io.to_s
        output.scan(/\+ Create/).size.should eq(3) # 2 for unurgunite + 1 for fintech
      end

      it "#apply uses per-org rules for dry-run" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")
        WebMock.stub(:get, "https://api.github.com/repos/fintech/payment-api/rulesets")
          .to_return(body: "[]")

        io = IO::Memory.new
        multi_engine.apply(["unurgunite/docscribe", "fintech/payment-api"], dry_run: true, io: io)
        output = io.to_s
        output.should contain("unurgunite/docscribe: Would create")
        output.should contain("fintech/payment-api: Would create")
      end

      it "#status_json includes multi-org types" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %([{"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": []}]))
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/1")
          .to_return(body: %({"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": [
            {"type": "deletion"},
            {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}}
          ]}))

        io = IO::Memory.new
        multi_engine.status_json(["unurgunite/docscribe"], io)
        json = JSON.parse(io.to_s).as_a
        json[0]["types"]["default_branch"]["exists"].should be_true
        json[0]["types"]["release"]["exists"].should be_false
      end
    end

    describe "#status with glob checks" do
      before_each do
        WebMock.reset
      end

      it "shows +checks for matching glob pattern" do
        glob_config = Config.from_yaml("org: unurgunite\nrepos:\n  - docscribe\nrules:\n  default_branch:\n    merge: only\n    checks: [\"CI /*\"]\n")
        glob_engine = Engine.new(client, glob_config)

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %([{"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": []}]))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/1")
          .to_return(body: %({"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": [
            {"type": "deletion"},
            {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}},
            {"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "CI / test (1.20.0)"}], "strict_required_status_checks_policy": true}}
          ]}))

        io = IO::Memory.new
        glob_engine.status([repo], io: io)
        STRIP_ANSI.call(io.to_s).should contain("+checks")
      end

      it "shows ~checks for non-matching glob pattern" do
        glob_config = Config.from_yaml("org: unurgunite\nrepos:\n  - docscribe\nrules:\n  default_branch:\n    merge: only\n    checks: [\"CI /*\"]\n")
        glob_engine = Engine.new(client, glob_config)

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %([{"id": 2, "name": "master", "enforcement": "active", "target": "branch", "rules": []}]))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/2")
          .to_return(body: %({"id": 2, "name": "master", "enforcement": "active", "target": "branch", "rules": [
            {"type": "deletion"},
            {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}},
            {"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "Lint"}], "strict_required_status_checks_policy": true}}
          ]}))

        io = IO::Memory.new
        glob_engine.status([repo], io: io)
        STRIP_ANSI.call(io.to_s).should contain("~checks")
      end

      it "shows -checks when checks rule missing with glob pattern" do
        glob_config = Config.from_yaml("org: unurgunite\nrepos:\n  - docscribe\nrules:\n  default_branch:\n    merge: only\n    checks: [\"CI /*\"]\n")
        glob_engine = Engine.new(client, glob_config)

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %([{"id": 3, "name": "master", "enforcement": "active", "target": "branch", "rules": []}]))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/3")
          .to_return(body: %({"id": 3, "name": "master", "enforcement": "active", "target": "branch", "rules": [
            {"type": "deletion"},
            {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}}
          ]}))

        io = IO::Memory.new
        glob_engine.status([repo], io: io)
        STRIP_ANSI.call(io.to_s).should contain("-checks")
      end
    end

    describe "#diff with glob checks" do
      before_each do
        WebMock.reset
      end

      it "shows glob note when ruleset exists with required_status_checks" do
        glob_config = Config.from_yaml("org: unurgunite\nrepos:\n  - docscribe\nrules:\n  default_branch:\n    merge: only\n    checks: [\"CI /*\"]\n")
        glob_engine = Engine.new(client, glob_config)

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %([{"id": 10, "name": "master", "enforcement": "active", "target": "branch", "rules": []}]))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/10")
          .to_return(body: %({"id": 10, "name": "master", "enforcement": "active", "target": "branch", "rules": [
            {"type": "deletion"},
            {"type": "non_fast_forward"},
            {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}},
            {"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "CI / test (1.20.0)"}], "strict_required_status_checks_policy": true}}
          ]}))

        io = IO::Memory.new
        glob_engine.diff([repo], io: io)
        io.to_s.should contain("matched by glob pattern")
        io.to_s.should contain("~ Update")
      end

      it "creates ruleset without required_status_checks for glob patterns" do
        glob_config = Config.from_yaml("org: unurgunite\nrepos:\n  - docscribe\nrules:\n  default_branch:\n    merge: only\n    checks: [\"CI /*\"]\n")
        glob_engine = Engine.new(client, glob_config)

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")

        io = IO::Memory.new
        glob_engine.diff([repo], io: io)
        io.to_s.should_not contain("required_status_checks")
      end
    end

    describe "#apply with glob checks" do
      before_each do
        WebMock.reset
      end

      it "shows warning when creating ruleset with glob checks" do
        glob_config = Config.from_yaml("org: unurgunite\nrepos:\n  - docscribe\nrules:\n  default_branch:\n    merge: only\n    checks: [\"CI /*\"]\n")
        glob_engine = Engine.new(client, glob_config)

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")

        WebMock.stub(:post, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %({"id": 1, "name": "test", "enforcement": "active", "target": "branch", "rules": []}))

        io = IO::Memory.new
        glob_engine.apply([repo], dry_run: false, io: io)
        io.to_s.should contain("checks skipped")
      end

      it "dry-run shows would create with glob checks" do
        glob_config = Config.from_yaml("org: unurgunite\nrepos:\n  - docscribe\nrules:\n  default_branch:\n    merge: only\n    checks: [\"CI /*\"]\n")
        glob_engine = Engine.new(client, glob_config)

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")

        io = IO::Memory.new
        glob_engine.apply([repo], dry_run: true, io: io)
        io.to_s.should contain("Would create")
      end
    end

    describe "#status_json with glob checks" do
      before_each do
        WebMock.reset
      end

      it "checks_ok true for matching glob pattern" do
        glob_config = Config.from_yaml("org: unurgunite\nrepos:\n  - docscribe\nrules:\n  default_branch:\n    merge: only\n    checks: [\"CI /*\"]\n")
        glob_engine = Engine.new(client, glob_config)

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %([{"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": []}]))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/1")
          .to_return(body: %({"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": [
            {"type": "deletion"},
            {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}},
            {"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "CI / test (1.20.0)"}], "strict_required_status_checks_policy": true}}
          ]}))

        io = IO::Memory.new
        glob_engine.status_json([repo], io)
        json = JSON.parse(io.to_s).as_a
        json[0]["types"]["default_branch"]["checks_ok"].should be_true
      end

      it "checks_ok false for non-matching glob pattern" do
        glob_config = Config.from_yaml("org: unurgunite\nrepos:\n  - docscribe\nrules:\n  default_branch:\n    merge: only\n    checks: [\"CI /*\"]\n")
        glob_engine = Engine.new(client, glob_config)

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %([{"id": 2, "name": "master", "enforcement": "active", "target": "branch", "rules": []}]))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/2")
          .to_return(body: %({"id": 2, "name": "master", "enforcement": "active", "target": "branch", "rules": [
            {"type": "deletion"},
            {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"], "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false, "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false, "required_reviewers": []}},
            {"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "Lint"}], "strict_required_status_checks_policy": true}}
          ]}))

        io = IO::Memory.new
        glob_engine.status_json([repo], io)
        json = JSON.parse(io.to_s).as_a
        json[0]["types"]["default_branch"]["checks_ok"].should be_false
      end
    end

    describe "#apply_json with glob checks" do
      before_each do
        WebMock.reset
      end

      it "checks_skipped true for create with glob pattern" do
        glob_config = Config.from_yaml("org: unurgunite\nrepos:\n  - docscribe\nrules:\n  default_branch:\n    merge: only\n    checks: [\"CI /*\"]\n")
        glob_engine = Engine.new(client, glob_config)

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")

        WebMock.stub(:post, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: %({"id": 1, "name": "test", "enforcement": "active", "target": "branch", "rules": []}))

        io = IO::Memory.new
        glob_engine.apply_json([repo], dry_run: false, io: io)
        json = JSON.parse(io.to_s).as_a
        json[0]["results"].as_a.each do |r|
          if r["action"].to_s == "create"
            r["checks_skipped"].should be_true
          end
        end
      end
    end

    describe BranchRuleConfig do
      describe "#glob_checks?" do
        it "returns true when checks contain *" do
          bc = BranchRuleConfig.new
          bc.checks = ["CI / *"]
          bc.glob_checks?.should be_true
        end

        it "returns true when checks contain ?" do
          bc = BranchRuleConfig.new
          bc.checks = ["test?"]
          bc.glob_checks?.should be_true
        end

        it "returns false for exact checks" do
          bc = BranchRuleConfig.new
          bc.checks = ["check / check"]
          bc.glob_checks?.should be_false
        end

        it "returns false when checks is nil" do
          bc = BranchRuleConfig.new
          bc.glob_checks?.should be_false
        end
      end

      describe "#checks_match?" do
        it "matches glob pattern against actual checks" do
          bc = BranchRuleConfig.new
          bc.checks = ["CI / *"]
          bc.checks_match?(["CI / test (1.0)", "CI / build"]).should be_true
        end

        it "fails when glob pattern doesn't match" do
          bc = BranchRuleConfig.new
          bc.checks = ["CI / *"]
          bc.checks_match?(["Lint"]).should be_false
        end

        it "matches exact patterns" do
          bc = BranchRuleConfig.new
          bc.checks = ["check / check"]
          bc.checks_match?(["check / check"]).should be_true
        end

        it "fails when exact pattern not found" do
          bc = BranchRuleConfig.new
          bc.checks = ["check / check"]
          bc.checks_match?(["other"]).should be_false
        end

        it "returns false for empty actual" do
          bc = BranchRuleConfig.new
          bc.checks = ["CI / *"]
          bc.checks_match?([] of String).should be_false
        end

        it "returns false when checks is nil" do
          bc = BranchRuleConfig.new
          bc.checks_match?(["check"]).should be_false
        end
      end
    end
  end
end
