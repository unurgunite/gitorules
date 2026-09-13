require "./spec_helper"
require "base64"

module Gitorules
  FS_TOKEN = "test-token"
  FS_REPO  = "unurgunite/docscribe"

  FS_SOURCES = [] of String

  def self.fs_source(content : String) : String
    path = File.join(Dir.tempdir, "gitorules-fs-#{rand(1_000_000_000)}-#{FS_SOURCES.size}.yml")
    File.write(path, content)
    FS_SOURCES << path
    path
  end

  def self.fs_config(target : String, source : String) : Config
    entry = WorkflowConfig.new
    entry.source = source
    config = Config.new
    config.files = {target => entry}
    config
  end

  def self.fs_contents_body(content : String, sha : String) : String
    encoded = Base64.strict_encode(content)
    %({"type":"file","encoding":"base64","size":#{content.bytesize},"name":"file","path":"x","content":"#{encoded}","sha":"#{sha}"})
  end

  def self.fs_contents_url(repo : String, target : String) : String
    "https://api.github.com/repos/#{repo}/contents/#{target}"
  end

  describe FileSync do
    describe ".allowed?" do
      it "allows linter configs" do
        FileSync.allowed?(".rubocop.yml").should be_true
        FileSync.allowed?(".ameba.yml").should be_true
      end

      it "allows version files" do
        FileSync.allowed?(".ruby-version").should be_true
        FileSync.allowed?(".nvmrc").should be_true
      end

      it "allows dependabot config" do
        FileSync.allowed?(".github/dependabot.yml").should be_true
      end

      it "allows issue templates" do
        FileSync.allowed?(".github/ISSUE_TEMPLATE/bug_report.md").should be_true
        FileSync.allowed?(".github/ISSUE_TEMPLATE/feature.md").should be_true
      end

      it "rejects nested issue templates" do
        FileSync.allowed?(".github/ISSUE_TEMPLATE/sub/bug.md").should be_false
      end

      it "rejects non-markdown issue templates" do
        FileSync.allowed?(".github/ISSUE_TEMPLATE/bug.txt").should be_false
      end

      it "allows workflow files" do
        FileSync.allowed?(".github/workflows/ci.yml").should be_true
        FileSync.allowed?(".github/workflows/ci.yaml").should be_true
      end

      it "rejects paths outside the allowlist" do
        FileSync.allowed?("evil.sh").should be_false
        FileSync.allowed?(".github/evil.yml").should be_false
        FileSync.allowed?(".github/workflows/../evil.yml").should be_false
        FileSync.allowed?("src/main.cr").should be_false
      end
    end

    describe ".class_for" do
      it "resolves each file class" do
        FileSync.class_for(".rubocop.yml").should eq "linter"
        FileSync.class_for(".ameba.yml").should eq "linter"
        FileSync.class_for(".ruby-version").should eq "version"
        FileSync.class_for(".nvmrc").should eq "version"
        FileSync.class_for(".github/dependabot.yml").should eq "dependabot"
        FileSync.class_for(".github/ISSUE_TEMPLATE/bug_report.md").should eq "issue_template"
        FileSync.class_for(".github/workflows/ci.yml").should eq "workflow"
      end

      it "returns nil outside the allowlist" do
        FileSync.class_for("evil.sh").should be_nil
      end
    end

    describe ".validate!" do
      it "accepts allowlisted targets" do
        entry = WorkflowConfig.new
        entry.source = "templates/x"
        FileSync.validate!({".rubocop.yml" => entry})
      end

      it "raises FileSyncError for disallowed targets" do
        entry = WorkflowConfig.new
        entry.source = "templates/evil"
        expect_raises(FileSyncError, /Invalid file target/) do
          FileSync.validate!({"evil.sh" => entry})
        end
      end
    end
  end

  describe FileResource do
    client = GitHubClient.new(FS_TOKEN)

    before_each do
      WebMock.reset
    end

    after_each do
      FS_SOURCES.each { |p| File.delete(p) if File.exists?(p) }
      FS_SOURCES.clear
    end

    describe "per-file-class sync" do
      it "creates a linter config on 404" do
        local = "AllCops:\n  NewCops: enable\n"
        src = Gitorules.fs_source(local)
        target = ".rubocop.yml"
        engine = Engine.new(client, Gitorules.fs_config(target, src))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")
        WebMock.stub(:get, Gitorules.fs_contents_url(FS_REPO, target))
          .to_return(status: 404, body: %({"message":"Not found"}))
        put_stub = WebMock.stub(:put, Gitorules.fs_contents_url(FS_REPO, target))
          .to_return(status: 201, body: %({"content":{"sha":"newsha"}}))

        io = IO::Memory.new
        engine.apply([FS_REPO], dry_run: false, io: io)
        put_stub.calls.should eq 1
        io.to_s.should contain("Created file '.rubocop.yml'")
      end

      it "updates a version file on sha mismatch" do
        old = "old\n"
        local = "3.2.2\n"
        src = Gitorules.fs_source(local)
        target = ".ruby-version"
        engine = Engine.new(client, Gitorules.fs_config(target, src))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")
        WebMock.stub(:get, Gitorules.fs_contents_url(FS_REPO, target))
          .to_return(body: Gitorules.fs_contents_body(old, WorkflowResource.blob_sha(old)))
        put_stub = WebMock.stub(:put, Gitorules.fs_contents_url(FS_REPO, target))
          .to_return(body: %({"content":{"sha":"newsha"}}))

        io = IO::Memory.new
        engine.apply([FS_REPO], dry_run: false, io: io)
        put_stub.calls.should eq 1
        io.to_s.should contain("Updated file '.ruby-version'")
      end

      it "skips a dependabot config on sha match with zero PUTs" do
        local = "version: 2\n"
        src = Gitorules.fs_source(local)
        target = ".github/dependabot.yml"
        engine = Engine.new(client, Gitorules.fs_config(target, src))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")
        WebMock.stub(:get, Gitorules.fs_contents_url(FS_REPO, target))
          .to_return(body: Gitorules.fs_contents_body(local, WorkflowResource.blob_sha(local)))
        put_stub = WebMock.stub(:put, /contents\//)

        io = IO::Memory.new
        engine.apply([FS_REPO], dry_run: false, io: io)
        put_stub.calls.should eq 0
        io.to_s.should_not contain("Updated file")
        io.to_s.should_not contain("Created file")
      end

      it "syncs an issue template" do
        local = "# Bug report\n"
        src = Gitorules.fs_source(local)
        target = ".github/ISSUE_TEMPLATE/bug_report.md"
        engine = Engine.new(client, Gitorules.fs_config(target, src))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")
        WebMock.stub(:get, Gitorules.fs_contents_url(FS_REPO, target))
          .to_return(status: 404, body: %({"message":"Not found"}))
        put_stub = WebMock.stub(:put, Gitorules.fs_contents_url(FS_REPO, target))
          .to_return(status: 201, body: %({"content":{"sha":"newsha"}}))

        io = IO::Memory.new
        engine.apply([FS_REPO], dry_run: false, io: io)
        put_stub.calls.should eq 1
        io.to_s.should contain("Created file '.github/ISSUE_TEMPLATE/bug_report.md'")
      end

      it "reports file changes in diff without writing" do
        old = "old\n"
        local = "new\n"
        src = Gitorules.fs_source(local)
        target = ".nvmrc"
        engine = Engine.new(client, Gitorules.fs_config(target, src))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")
        WebMock.stub(:get, Gitorules.fs_contents_url(FS_REPO, target))
          .to_return(body: Gitorules.fs_contents_body(old, WorkflowResource.blob_sha(old)))
        put_stub = WebMock.stub(:put, /contents\//)

        io = IO::Memory.new
        engine.diff([FS_REPO], io: io)
        put_stub.calls.should eq 0
        io.to_s.should contain("Update file '.nvmrc'")
      end

      it "dry-run performs zero PUTs" do
        old = "old\n"
        local = "new\n"
        src = Gitorules.fs_source(local)
        target = ".ameba.yml"
        engine = Engine.new(client, Gitorules.fs_config(target, src))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")
        WebMock.stub(:get, Gitorules.fs_contents_url(FS_REPO, target))
          .to_return(body: Gitorules.fs_contents_body(old, WorkflowResource.blob_sha(old)))
        put_stub = WebMock.stub(:put, /contents\//)

        io = IO::Memory.new
        engine.apply([FS_REPO], dry_run: true, io: io)
        put_stub.calls.should eq 0
        io.to_s.should contain("Would update file '.ameba.yml'")
      end
    end

    describe "allowlist rejection pre-write" do
      it "rejects disallowed targets before any write" do
        engine = Engine.new(client, Gitorules.fs_config("evil.sh", "templates/evil.sh"))
        put_stub = WebMock.stub(:put, /contents\//)

        io = IO::Memory.new
        expect_raises(FileSyncError, /Invalid file target/) do
          engine.apply([FS_REPO], dry_run: false, io: io)
        end
        put_stub.calls.should eq 0
      end

      it "exits 2 on disallowed file targets via CLI" do
        config_yaml = "org: unurgunite\nrepos:\n  - unurgunite/docscribe\nfiles:\n  evil.sh:\n    source: templates/evil.sh\n"
        path = File.join(Dir.tempdir, "gitorules-fs-cli-#{rand(1_000_000_000)}.yml")
        File.write(path, config_yaml)

        CLI.run(["--token", "test", "--config", path, "diff", "--repo", FS_REPO]).should eq 2
      ensure
        File.delete(path) if path && File.exists?(path)
      end
    end

    describe "config" do
      it "parses files from YAML" do
        config = Config.from_yaml("org: unurgunite\nrepos:\n  - docscribe\nfiles:\n  .rubocop.yml:\n    source: templates/.rubocop.yml\n")
        files = config.files_for("unurgunite/docscribe")
        files.should_not be_nil
        files.try(&.[".rubocop.yml"].source).should eq "templates/.rubocop.yml"
      end

      it "resolves per-org files" do
        config = Config.from_yaml("orgs:\n  unurgunite:\n    repos:\n      - docscribe\n    files:\n      .nvmrc:\n        source: templates/.nvmrc\n")
        config.files_for("unurgunite/docscribe").should_not be_nil
        config.files_for("other/repo").should be_nil
      end
    end
  end
end
