require "./spec_helper"
require "yaml"

module Gitorules
  describe "Ruby pack" do
    describe "template structure" do
      template_path = File.join(__DIR__, "..", "templates", "ruby", "ci.yml")

      it "exists and parses as valid YAML" do
        File.exists?(template_path).should be_true
        parsed = YAML.parse(File.read(template_path))
        parsed.as_h?.should_not be_nil
      end

      it "defines a single test job" do
        parsed = YAML.parse(File.read(template_path))
        jobs = parsed["jobs"].as_h
        names = jobs.keys.compact_map(&.as_s?)
        names.should eq ["test"]
      end

      it "runs an rspec matrix across ruby 3.1 to 3.4" do
        parsed = YAML.parse(File.read(template_path))
        matrix = parsed["jobs"]["test"]["strategy"]["matrix"]["ruby"].as_a.map(&.as_s)
        matrix.should contain "3.1"
        matrix.should contain "3.2"
        matrix.should contain "3.3"
        matrix.should contain "3.4"
      end

      it "uses bundler cache, rubocop and rspec" do
        content = File.read(template_path)
        content.should contain "bundler-cache"
        content.should contain "rubocop"
        content.should contain "rspec"
        content.should contain "ruby-version"
      end
    end

    describe "--only vocabulary lock" do
      it "accepts only branch, labels, workflows and files" do
        ScopeResolver::VALID_ONLY_VALUES.should eq ["branch", "labels", "workflows", "files"]
        ScopeResolver::VALID_ONLY_VALUES.should_not contain "rulesets"
      end

      it "parses branch, labels, workflows and files combinations" do
        ScopeResolver.parse_only("branch").should eq Set{"branch"}
        ScopeResolver.parse_only("labels").should eq Set{"labels"}
        ScopeResolver.parse_only("workflows").should eq Set{"workflows"}
        ScopeResolver.parse_only("files").should eq Set{"files"}
        ScopeResolver.parse_only("branch,labels").should eq Set{"branch", "labels"}
        ScopeResolver.parse_only("branch,labels,workflows").should eq Set{"branch", "labels", "workflows"}
      end

      it "rejects the legacy rulesets value" do
        expect_raises(ArgumentError, /Valid values: branch, labels, workflows, files/) do
          ScopeResolver.parse_only("rulesets")
        end
        expect_raises(ArgumentError, /Valid values/) do
          ScopeResolver.parse_only("branch,rulesets")
        end
      end

      it "CLI rejects --only rulesets with exit 2" do
        path = File.join(Dir.tempdir, "ruby-pack-only-#{Random.rand(100000)}.yml")
        File.write(path, "org: unurgunite\nrepos:\n  - docscribe\nrules:\n  default_branch:\n    merge: only\n")
        CLI.run(["--token", "test", "--config", path, "status", "--only", "rulesets"]).should eq 2
        CLI.run(["--token", "test", "--config", path, "status", "--only", "branch,rulesets"]).should eq 2
      ensure
        File.delete(path) if path && File.exists?(path)
      end

      it "CLI accepts --only branch,labels,workflows" do
        path = File.join(Dir.tempdir, "ruby-pack-only-ok-#{Random.rand(100000)}.yml")
        File.write(path, "org: unurgunite\nrepos:\n  - docscribe\nrules:\n  default_branch:\n    merge: only\n")
        WebMock.reset
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")
        CLI.run(["--token", "test", "--config", path, "status", "--repo", "unurgunite/docscribe", "--only", "branch"]).should eq 0
        CLI.run(["--token", "test", "--config", path, "status", "--repo", "unurgunite/docscribe", "--only", "branch,labels,workflows"]).should eq 0
      ensure
        File.delete(path) if path && File.exists?(path)
        WebMock.reset
      end
    end

    describe "scope and only aware status summary" do
      token = "test-token"
      repo = "unurgunite/docscribe"
      client = GitHubClient.new(token)
      branch_config = Config.from_yaml("org: unurgunite\nrepos:\n  - docscribe\nrules:\n  default_branch:\n    merge: only\n")
      labels_config = Config.from_yaml("org: unurgunite\nrepos:\n  - docscribe\nrules:\n  default_branch:\n    merge: only\nlabels:\n  - name: bug\n    color: d73a4a\n")

      before_each do
        WebMock.reset
      end

      it "default run reports branch rules without rulesets wording" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")
        engine = Engine.new(client, branch_config)
        io = IO::Memory.new
        engine.status([repo], io: io)
        output = io.to_s
        output.should contain "All branch rules up to date"
        output.should_not contain "rulesets"
      end

      it "branch-only run reports branch rules" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")
        engine = Engine.new(client, branch_config)
        io = IO::Memory.new
        engine.status([repo], io: io, only: "branch")
        output = io.to_s
        output.should contain "All branch rules up to date"
        output.should_not contain "rulesets"
      end

      it "labels-only run reports labels and never mentions rulesets" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/labels?per_page=100")
          .to_return(body: "[]")
        engine = Engine.new(client, labels_config)
        io = IO::Memory.new
        engine.status([repo], io: io, only: "labels")
        output = io.to_s
        output.should contain "All labels up to date"
        output.should_not contain "rulesets"
        output.should_not contain "branch rules"
      end

      it "workflows-only run reports workflows without rulesets wording" do
        engine = Engine.new(client, branch_config)
        io = IO::Memory.new
        engine.status([repo], io: io, only: "workflows")
        output = io.to_s
        output.should contain "All workflows up to date"
        output.should_not contain "rulesets"
      end

      it "branch and labels run reports both subsystems" do
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/labels?per_page=100")
          .to_return(body: "[]")
        engine = Engine.new(client, labels_config)
        io = IO::Memory.new
        engine.status([repo], io: io, only: "branch,labels")
        output = io.to_s
        output.should contain "All branch rules and labels up to date"
        output.should_not contain "rulesets"
      end
    end

    describe "example config" do
      it "parses defaults with ruby-gems and crystal-shards scopes" do
        path = File.join(__DIR__, "..", ".gitorules.yml.example")
        File.exists?(path).should be_true
        config = Config.from_yaml(File.read(path))
        resolver = ScopeResolver.new(config)
        resolver.scope_names.should contain "ruby-gems"
        resolver.scope_names.should contain "crystal-shards"
        ruby_repos = resolver.repos_for_scope("ruby-gems", ["unurgunite/docscribe", "unurgunite/genius-api", "unurgunite/gitorules"])
        ruby_repos.should contain "unurgunite/docscribe"
        ruby_repos.should contain "unurgunite/genius-api"
        rules = resolver.effective_rules("unurgunite/docscribe")
        rules.should_not be_nil
      end

      it "passes lint clean" do
        path = File.join(__DIR__, "..", ".gitorules.yml.example")
        result = Linter.lint_content(File.read(path), ".gitorules.yml.example")
        result.errors.should be_empty
      end
    end
  end
end
