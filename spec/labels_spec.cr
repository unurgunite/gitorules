require "./spec_helper"

module Gitorules
  describe GitHubClient do
    token = "test-token"
    repo = "unurgunite/docscribe"
    client = GitHubClient.new(token)

    describe "#list_labels" do
      it "returns an array of labels" do
        WebMock.reset
        body = %([{"name": "bug", "color": "d73a4a", "description": "Something is broken"}])
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/labels?per_page=100")
          .to_return(body: body, headers: {"Content-Type" => "application/json"})

        result = client.list_labels(repo)
        result.size.should eq 1
        result[0].name.should eq "bug"
        result[0].color.should eq "d73a4a"
        result[0].description.should eq "Something is broken"
      end

      it "raises on 404" do
        WebMock.reset
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/unknown/labels?per_page=100")
          .to_return(status: 404)

        expect_raises(Exception, "Not found") do
          client.list_labels("unurgunite/unknown")
        end
      end
    end

    describe "#create_label" do
      it "posts and returns the new label" do
        WebMock.reset
        WebMock.stub(:post, "https://api.github.com/repos/unurgunite/docscribe/labels")
          .to_return(status: 201, body: %({"name": "bug", "color": "d73a4a", "description": "Something is broken"}))

        result = client.create_label(repo, Label.new("bug", "d73a4a", "Something is broken"))
        result.name.should eq "bug"
        result.color.should eq "d73a4a"
      end
    end

    describe "#update_label" do
      it "patches and returns the updated label" do
        WebMock.reset
        WebMock.stub(:patch, "https://api.github.com/repos/unurgunite/docscribe/labels/bug")
          .to_return(body: %({"name": "bug", "color": "d73a4a", "description": "New description"}))

        result = client.update_label(repo, "bug", Label.new("bug", "d73a4a", "New description"))
        result.description.should eq "New description"
      end

      it "encodes special characters in the label name" do
        WebMock.reset
        WebMock.stub(:patch, "https://api.github.com/repos/unurgunite/docscribe/labels/help%20wanted")
          .to_return(body: %({"name": "help wanted", "color": "008672", "description": null}))

        result = client.update_label(repo, "help wanted", Label.new("help wanted", "008672"))
        result.name.should eq "help wanted"
      end
    end

    describe "#delete_label" do
      it "deletes and returns nil" do
        WebMock.reset
        WebMock.stub(:delete, "https://api.github.com/repos/unurgunite/docscribe/labels/stale")
          .to_return(status: 204, body: "")

        client.delete_label(repo, "stale").should be_nil
      end

      it "raises on 404" do
        WebMock.reset
        WebMock.stub(:delete, "https://api.github.com/repos/unurgunite/docscribe/labels/missing")
          .to_return(status: 404)

        expect_raises(Exception, "Not found") do
          client.delete_label(repo, "missing")
        end
      end
    end
  end

  describe Label do
    it "normalizes color for comparison" do
      Label.new("bug", "#D73A4A").norm_color.should eq "d73a4a"
      Label.new("bug", "d73a4a").norm_color.should eq "d73a4a"
    end

    it "treats nil and blank descriptions as equal" do
      Label.new("bug", "d73a4a").norm_description.should eq ""
      Label.new("bug", "d73a4a", "  ").norm_description.should eq ""
    end
  end

  describe LabelsSync do
    it "defaults to warn" do
      config = Config.from_yaml("org: unurgunite\nrepos:\n  - docscribe\n")
      LabelsSync.mode(config).should eq "warn"
    end

    it "accepts prune, warn, and ignore" do
      ["prune", "warn", "ignore"].each do |mode|
        config = Config.from_yaml("org: unurgunite\nrepos:\n  - docscribe\nlabels_sync: #{mode}\nlabels:\n  - name: bug\n    color: d73a4a\n")
        LabelsSync.mode(config).should eq mode
      end
    end

    it "raises on unknown mode" do
      config = Config.from_yaml("org: unurgunite\nrepos:\n  - docscribe\nlabels_sync: destroy\n")
      expect_raises(Exception, /labels_sync/) do
        LabelsSync.validate!(config)
      end
    end
  end

  describe LabelResource do
    token = "test-token"
    repo = "unurgunite/docscribe"
    client = GitHubClient.new(token)

    labels_config = Config.from_yaml(<<-YAML)
      org: unurgunite
      repos:
        - docscribe
      labels:
        - name: bug
          color: d73a4a
          description: Something is broken
        - name: help wanted
          color: "008672"
          description: Extra attention is needed
      YAML

    prune_config = Config.from_yaml(<<-YAML)
      org: unurgunite
      repos:
        - docscribe
      labels_sync: prune
      labels:
        - name: bug
          color: d73a4a
          description: Something is broken
      YAML

    ignore_config = Config.from_yaml(<<-YAML)
      org: unurgunite
      repos:
        - docscribe
      labels_sync: ignore
      labels:
        - name: bug
          color: d73a4a
          description: Something is broken
      YAML

    before_each do
      WebMock.reset
    end

    describe "#build_entries" do
      it "marks matching labels unchanged despite case and # prefix" do
        resource = LabelResource.new(client, labels_config)
        wants = [Label.new("bug", "d73a4a", "Something is broken")]
        actual = [Label.new("bug", "#D73A4A", "Something is broken")]
        entries = resource.build_entries(wants, actual, "warn")
        entries.size.should eq 1
        entries[0].action.should eq "unchanged"
      end

      it "detects color and description updates" do
        resource = LabelResource.new(client, labels_config)
        wants = [Label.new("bug", "d73a4a", "New description")]
        actual = [Label.new("bug", "000000", "Old description")]
        entries = resource.build_entries(wants, actual, "warn")
        entries.size.should eq 1
        entries[0].action.should eq "update"
        entries[0].changes.join(" ").should contain("color")
        entries[0].changes.join(" ").should contain("description")
      end

      it "reports orphans on warn and skips them on ignore" do
        resource = LabelResource.new(client, labels_config)
        wants = [Label.new("bug", "d73a4a")]
        actual = [Label.new("bug", "d73a4a"), Label.new("stray", "ffffff")]
        warn_entries = resource.build_entries(wants, actual, "warn")
        warn_entries.map(&.action).should contain("orphan")
        ignore_entries = resource.build_entries(wants, actual, "ignore")
        ignore_entries.map(&.action).should_not contain("orphan")
        ignore_entries.size.should eq 1
      end
    end

    describe "apply" do
      it "creates missing labels" do
        engine = Engine.new(client, labels_config)
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/labels?per_page=100")
          .to_return(body: "[]")
        WebMock.stub(:post, "https://api.github.com/repos/unurgunite/docscribe/labels")
          .to_return(status: 201, body: %({"name": "bug", "color": "d73a4a", "description": "Something is broken"}))

        io = IO::Memory.new
        engine.apply([repo], dry_run: false, io: io, only: "labels")
        io.to_s.should contain("Created label 'bug'")
      end

      it "updates labels when color or description differ" do
        engine = Engine.new(client, labels_config)
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/labels?per_page=100")
          .to_return(body: %([
            {"name": "bug", "color": "000000", "description": "Old description"},
            {"name": "help wanted", "color": "008672", "description": "Extra attention is needed"}
          ]))
        WebMock.stub(:patch, "https://api.github.com/repos/unurgunite/docscribe/labels/bug")
          .to_return(body: %({"name": "bug", "color": "d73a4a", "description": "Something is broken"}))

        io = IO::Memory.new
        engine.apply([repo], dry_run: false, io: io, only: "labels")
        io.to_s.should contain("Updated label 'bug'")
      end

      it "deletes orphans on prune" do
        engine = Engine.new(client, prune_config)
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/labels?per_page=100")
          .to_return(body: %([
            {"name": "bug", "color": "d73a4a", "description": "Something is broken"},
            {"name": "stray", "color": "ffffff", "description": ""}
          ]))
        WebMock.stub(:delete, "https://api.github.com/repos/unurgunite/docscribe/labels/stray")
          .to_return(status: 204, body: "")

        io = IO::Memory.new
        engine.apply([repo], dry_run: false, io: io, only: "labels")
        io.to_s.should contain("Deleted label 'stray'")
      end

      it "never deletes on default warn mode" do
        engine = Engine.new(client, labels_config)
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/labels?per_page=100")
          .to_return(body: %([
            {"name": "bug", "color": "d73a4a", "description": "Something is broken"},
            {"name": "help wanted", "color": "008672", "description": "Extra attention is needed"},
            {"name": "stray", "color": "ffffff", "description": ""}
          ]))

        io = IO::Memory.new
        engine.apply([repo], dry_run: false, io: io, only: "labels")
        output = io.to_s
        output.should contain("Orphan label 'stray'")
        output.should contain("warn only")
        output.should_not contain("Deleted label")
      end

      it "performs zero writes on dry-run" do
        engine = Engine.new(client, prune_config)
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/labels?per_page=100")
          .to_return(body: %([
            {"name": "bug", "color": "000000", "description": "Old"},
            {"name": "stray", "color": "ffffff", "description": ""}
          ]))

        io = IO::Memory.new
        engine.apply([repo], dry_run: true, io: io, only: "labels")
        output = io.to_s
        output.should contain("Would update label 'bug'")
        output.should contain("Would delete label 'stray' (prune)")
      end

      it "dry-run reports creates without writing" do
        engine = Engine.new(client, prune_config)
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/labels?per_page=100")
          .to_return(body: "[]")

        io = IO::Memory.new
        engine.apply([repo], dry_run: true, io: io, only: "labels")
        io.to_s.should contain("Would create label 'bug'")
      end
    end

    describe "diff" do
      it "shows create, update, and orphan lines" do
        engine = Engine.new(client, labels_config)
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/labels?per_page=100")
          .to_return(body: %([
            {"name": "bug", "color": "000000", "description": "Old"},
            {"name": "stray", "color": "ffffff", "description": ""}
          ]))

        io = IO::Memory.new
        engine.diff([repo], io: io, only: "labels")
        output = io.to_s
        output.should contain("Update label 'bug'")
        output.should contain("Create label 'help wanted'")
        output.should contain("Orphan label 'stray'")
      end

      it "shows no changes when labels match" do
        engine = Engine.new(client, prune_config)
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/labels?per_page=100")
          .to_return(body: %([{"name": "bug", "color": "d73a4a", "description": "Something is broken"}]))

        io = IO::Memory.new
        engine.diff([repo], io: io, only: "labels")
        io.to_s.should contain("no changes")
      end

      it "omits orphans on ignore" do
        engine = Engine.new(client, ignore_config)
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/labels?per_page=100")
          .to_return(body: %([
            {"name": "bug", "color": "d73a4a", "description": "Something is broken"},
            {"name": "stray", "color": "ffffff", "description": ""}
          ]))

        io = IO::Memory.new
        engine.diff([repo], io: io, only: "labels")
        io.to_s.should_not contain("stray")
      end
    end

    describe "JSON output" do
      it "follows {repo, resource, action, changes[]} with all actions" do
        engine = Engine.new(client, labels_config)
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/labels?per_page=100")
          .to_return(body: %([
            {"name": "bug", "color": "d73a4a", "description": "Something is broken"},
            {"name": "help wanted", "color": "000000", "description": "Old"},
            {"name": "stray", "color": "ffffff", "description": ""}
          ]))
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")

        io = IO::Memory.new
        engine.diff_json([repo], io, "labels")
        json = JSON.parse(io.to_s).as_a
        changes = json[0]["changes"].as_a
        by_name = {} of String => JSON::Any
        changes.each { |c| by_name[c["name"].to_s] = c }
        by_name["bug"]["action"].to_s.should eq "unchanged"
        by_name["help wanted"]["action"].to_s.should eq "update"
        by_name["stray"]["action"].to_s.should eq "orphan"
        changes.each do |c|
          c["repo"].to_s.should eq repo
          c["resource"].to_s.should eq "labels"
          c["changes"].as_a.should be_a(Array(JSON::Any))
        end
      end

      it "reports create action for missing labels" do
        engine = Engine.new(client, prune_config)
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/labels?per_page=100")
          .to_return(body: "[]")

        io = IO::Memory.new
        engine.apply_json([repo], dry_run: true, io: io, only: "labels")
        json = JSON.parse(io.to_s).as_a
        results = json[0]["results"].as_a
        results.size.should eq 1
        results[0]["action"].to_s.should eq "create"
        results[0]["resource"].to_s.should eq "labels"
        results[0]["dry_run"].should be_true
      end

      it "status JSON includes labels entries" do
        engine = Engine.new(client, labels_config)
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/labels?per_page=100")
          .to_return(body: %([{"name": "bug", "color": "d73a4a", "description": "Something is broken"}]))
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")

        io = IO::Memory.new
        engine.status_json([repo], io, "labels")
        json = JSON.parse(io.to_s).as_a
        labels = json[0]["labels"].as_a
        labels.map(&.["name"].to_s).should contain("bug")
        labels.map(&.["name"].to_s).should contain("help wanted")
      end
    end

    describe "--only filtering" do
      it "skips rulesets when only labels is set" do
        engine = Engine.new(client, labels_config)
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/labels?per_page=100")
          .to_return(body: "[]")

        io = IO::Memory.new
        engine.diff([repo], io: io, only: "labels")
        io.to_s.should contain("Create label")
      end

      it "skips labels when only rulesets is set" do
        engine = Engine.new(client, labels_config)
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")

        io = IO::Memory.new
        engine.diff([repo], io: io, only: "rulesets")
        io.to_s.should_not contain("label")
      end

      it "runs both resources by default" do
        both_config = Config.from_yaml(<<-YAML)
          org: unurgunite
          repos:
            - docscribe
          rules:
            default_branch:
              merge: only
          labels:
            - name: bug
              color: d73a4a
          YAML
        engine = Engine.new(client, both_config)
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/labels?per_page=100")
          .to_return(body: "[]")

        io = IO::Memory.new
        engine.diff([repo], io: io)
        io.to_s.should contain("Create ruleset")
        io.to_s.should contain("Create label")
      end
    end

    describe "CLI" do
      it "rejects unknown --only values with exit 2" do
        path = File.join(Dir.tempdir, "labels-only-reject.yml")
        File.write(path, "org: unurgunite\nrepos:\n  - docscribe\n")
        CLI.run(["--token", "test", "--config", path, "status", "--only", "bogus"]).should eq(2)
      ensure
        File.delete(path) if path && File.exists?(path)
      end

      it "rejects invalid labels_sync with exit 2" do
        path = File.join(Dir.tempdir, "labels-sync-reject.yml")
        File.write(path, "org: unurgunite\nrepos:\n  - docscribe\nlabels_sync: destroy\nlabels:\n  - name: bug\n    color: d73a4a\n")
        CLI.run(["--token", "test", "--config", path, "status"]).should eq(2)
      ensure
        File.delete(path) if path && File.exists?(path)
      end
    end
  end
end
