require "./spec_helper"
require "base64"
require "file_utils"

module Gitorules
  REMOTE_TOKEN = "test-token"
  REMOTE_REPO  = "unurgunite/docscribe"

  def self.remote_contents_body(content : String, sha : String) : String
    encoded = Base64.strict_encode(content)
    %({"type":"file","encoding":"base64","size":#{content.bytesize},"name":"ci.yml","path":"ruby/ci.yml","content":"#{encoded}","sha":"#{sha}"})
  end

  def self.remote_config(source : String, key : String = "ci.yml") : Config
    entry = WorkflowConfig.new
    entry.source = source
    config = Config.new
    config.workflows = {key => entry}
    config
  end

  describe TemplateSource do
    describe ".parse" do
      it "parses local paths" do
        src = TemplateSource.parse("templates/ci.yml")
        src.local?.should be_true
        src.remote?.should be_false
        src.path.should eq "templates/ci.yml"
      end

      it "parses tag pins" do
        src = TemplateSource.parse("FlorexLabs/templates@v1:ruby/ci.yml")
        src.remote?.should be_true
        src.repo.should eq "FlorexLabs/templates"
        src.ref.should eq "v1"
        src.path.should eq "ruby/ci.yml"
        src.sha_pin?.should be_false
      end

      it "parses sha pins" do
        sha = "a" * 40
        src = TemplateSource.parse("FlorexLabs/templates@#{sha}:ruby/ci.yml")
        src.remote?.should be_true
        src.sha_pin?.should be_true
        src.ref.should eq sha
      end

      it "rejects invalid sources" do
        expect_raises(WorkflowError) { TemplateSource.parse("norepo@v1:path/file.yml") }
        expect_raises(WorkflowError) { TemplateSource.parse("@v1:path/file.yml") }
        expect_raises(WorkflowError) { TemplateSource.parse("owner/repo@:path/file.yml") }
        expect_raises(WorkflowError) { TemplateSource.parse("owner/repo@v1:") }
        expect_raises(WorkflowError) { TemplateSource.parse("  ") }
      end
    end
  end

  describe TemplateResolver do
    client = GitHubClient.new(REMOTE_TOKEN)

    before_each do
      WebMock.reset
      TemplateResolver.clear_cache!
    end

    it "resolves tag pins via Contents API" do
      content = "name: CI\non: [push]\n"
      sha = WorkflowResource.blob_sha(content)
      WebMock.stub(:get, "https://api.github.com/repos/FlorexLabs/templates/contents/ruby/ci.yml?ref=v1")
        .to_return(body: Gitorules.remote_contents_body(content, sha))

      resolver = TemplateResolver.new(client)
      resolved = resolver.resolve("FlorexLabs/templates@v1:ruby/ci.yml")
      resolved.content.should eq content
      resolved.blob_sha.should eq sha
    end

    it "resolves sha pins via Contents API" do
      sha_pin = "b" * 40
      content = "jobs:\n  build:\n"
      blob = WorkflowResource.blob_sha(content)
      WebMock.stub(:get, "https://api.github.com/repos/FlorexLabs/templates/contents/ruby/ci.yml?ref=#{sha_pin}")
        .to_return(body: Gitorules.remote_contents_body(content, blob))

      resolver = TemplateResolver.new(client)
      resolved = resolver.resolve("FlorexLabs/templates@#{sha_pin}:ruby/ci.yml")
      resolved.content.should eq content
      resolved.blob_sha.should eq blob
    end

    it "caches downloads: second resolve performs zero HTTP calls" do
      content = "cached: true\n"
      sha = WorkflowResource.blob_sha(content)
      stub = WebMock.stub(:get, "https://api.github.com/repos/FlorexLabs/templates/contents/ruby/ci.yml?ref=v1")
        .to_return(body: Gitorules.remote_contents_body(content, sha))

      resolver = TemplateResolver.new(client)
      resolver.resolve("FlorexLabs/templates@v1:ruby/ci.yml")
      stub.calls.should eq 1
      resolver.resolve("FlorexLabs/templates@v1:ruby/ci.yml")
      stub.calls.should eq 1
    end

    it "is reproducible: same pin gives same content" do
      content = "stable: 1\n"
      sha = WorkflowResource.blob_sha(content)
      WebMock.stub(:get, "https://api.github.com/repos/FlorexLabs/templates/contents/ruby/ci.yml?ref=v1")
        .to_return(body: Gitorules.remote_contents_body(content, sha))

      resolver = TemplateResolver.new(client)
      first = resolver.resolve("FlorexLabs/templates@v1:ruby/ci.yml")
      second = resolver.resolve("FlorexLabs/templates@v1:ruby/ci.yml")
      first.content.should eq second.content
      first.blob_sha.should eq second.blob_sha
      first.content.should eq content
    end

    it "uses disk cache for offline-friendly repeated runs" do
      content = "disk: cached\n"
      sha = WorkflowResource.blob_sha(content)
      stub = WebMock.stub(:get, "https://api.github.com/repos/FlorexLabs/templates/contents/ruby/ci.yml?ref=v1")
        .to_return(body: Gitorules.remote_contents_body(content, sha))

      dir = File.join(Dir.tempdir, "gitorules-cache-#{Random.rand(1_000_000_000)}")
      begin
        first_resolver = TemplateResolver.new(client, dir)
        first = first_resolver.resolve("FlorexLabs/templates@v1:ruby/ci.yml")
        first.content.should eq content
        stub.calls.should eq 1

        TemplateResolver.clear_cache!
        WebMock.reset
        offline_stub = WebMock.stub(:get, /templates\/contents\//)

        second_resolver = TemplateResolver.new(client, dir)
        second = second_resolver.resolve("FlorexLabs/templates@v1:ruby/ci.yml")
        second.content.should eq content
        offline_stub.calls.should eq 0
      ensure
        FileUtils.rm_rf(dir) if Dir.exists?(dir)
      end
    end
  end

  describe "remote templates via Engine" do
    client = GitHubClient.new(REMOTE_TOKEN)

    before_each do
      WebMock.reset
      TemplateResolver.clear_cache!
    end

    it "rejects disallowed targets before any write" do
      engine = Engine.new(client, Gitorules.remote_config("FlorexLabs/templates@v1:ruby/ci.yml", "evil.sh"))
      put_stub = WebMock.stub(:put, /contents\//)

      io = IO::Memory.new
      expect_raises(WorkflowError, /only .github\/workflows\/\*\.yml/) do
        engine.apply([REMOTE_REPO], dry_run: false, io: io)
      end
      put_stub.calls.should eq 0
    end

    it "dry-run performs zero PUTs for remote pins" do
      content = "name: CI\non: [push]\n"
      sha = WorkflowResource.blob_sha(content)
      old = "old content\n"

      WebMock.stub(:get, "https://api.github.com/repos/FlorexLabs/templates/contents/ruby/ci.yml?ref=v1")
        .to_return(body: Gitorules.remote_contents_body(content, sha))
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
        .to_return(body: "[]")
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/contents/.github/workflows/ci.yml")
        .to_return(body: Gitorules.remote_contents_body(old, WorkflowResource.blob_sha(old)))
      put_stub = WebMock.stub(:put, /contents\//)

      engine = Engine.new(client, Gitorules.remote_config("FlorexLabs/templates@v1:ruby/ci.yml"))
      io = IO::Memory.new
      engine.apply([REMOTE_REPO], dry_run: true, io: io)
      put_stub.calls.should eq 0
      io.to_s.should contain("Would update workflow '.github/workflows/ci.yml'")
    end

    it "reports pin resolution in diff --verbose" do
      content = "name: CI\non: [push]\n"
      sha = WorkflowResource.blob_sha(content)

      WebMock.stub(:get, "https://api.github.com/repos/FlorexLabs/templates/contents/ruby/ci.yml?ref=v1")
        .to_return(body: Gitorules.remote_contents_body(content, sha))
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
        .to_return(body: "[]")
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/contents/.github/workflows/ci.yml")
        .to_return(status: 404, body: %({"message":"Not found"}))

      engine = Engine.new(client, Gitorules.remote_config("FlorexLabs/templates@v1:ruby/ci.yml"))
      io = IO::Memory.new
      engine.diff([REMOTE_REPO], verbose: true, io: io)
      io.to_s.should contain("FlorexLabs/templates@v1:ruby/ci.yml")
      io.to_s.should contain(sha)
    end

    it "records resolved sha in JSON output" do
      content = "name: CI\non: [push]\n"
      sha = WorkflowResource.blob_sha(content)

      WebMock.stub(:get, "https://api.github.com/repos/FlorexLabs/templates/contents/ruby/ci.yml?ref=v1")
        .to_return(body: Gitorules.remote_contents_body(content, sha))
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
        .to_return(body: "[]")
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/contents/.github/workflows/ci.yml")
        .to_return(status: 404, body: %({"message":"Not found"}))

      engine = Engine.new(client, Gitorules.remote_config("FlorexLabs/templates@v1:ruby/ci.yml"))
      io = IO::Memory.new
      engine.diff_json([REMOTE_REPO], io)
      json = JSON.parse(io.to_s).as_a
      entries = json[0]["changes"].as_a
      wf = entries.find { |e| e["resource"].to_s == ".github/workflows/ci.yml" }
      wf.should_not be_nil
      if entry = wf
        entry["source"].to_s.should contain("FlorexLabs/templates@v1")
        entry["resolved_sha"].to_s.should eq sha
        entry["ref"].to_s.should eq "v1"
      end
    end

    it "skips update on sha match for remote pins" do
      content = "name: CI\non: [push]\n"
      sha = WorkflowResource.blob_sha(content)

      WebMock.stub(:get, "https://api.github.com/repos/FlorexLabs/templates/contents/ruby/ci.yml?ref=v1")
        .to_return(body: Gitorules.remote_contents_body(content, sha))
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
        .to_return(body: "[]")
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/contents/.github/workflows/ci.yml")
        .to_return(body: Gitorules.remote_contents_body(content, sha))
      put_stub = WebMock.stub(:put, /contents\//)

      engine = Engine.new(client, Gitorules.remote_config("FlorexLabs/templates@v1:ruby/ci.yml"))
      io = IO::Memory.new
      engine.apply([REMOTE_REPO], dry_run: false, io: io)
      put_stub.calls.should eq 0
    end
  end

  describe Linter do
    it "accepts remote workflow sources" do
      result = Linter.lint_content(<<-YAML, "remote.yml")
        org: test
        repos:
          - r
        rules:
          default_branch:
            merge: only
        workflows:
          ci.yml:
            source: FlorexLabs/templates@v1:ruby/ci.yml
        YAML
      result.errors.should be_empty
    end

    it "rejects invalid remote sources" do
      result = Linter.lint_content(<<-YAML, "bad-remote.yml")
        org: test
        repos:
          - r
        rules:
          default_branch:
            merge: only
        workflows:
          ci.yml:
            source: badrepo@v1:path/file.yml
        YAML
      result.errors.any?(&.includes?("workflows.ci.yml.source")).should be_true
    end
  end
end
