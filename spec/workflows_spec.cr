require "./spec_helper"
require "base64"

module Gitorules
  WF_TOKEN = "test-token"
  WF_REPO  = "unurgunite/docscribe"
  WF_URL   = "https://api.github.com/repos/unurgunite/docscribe/contents/.github/workflows/ci.yml"
  WF_LOCAL = "name: CI\non: [push]\n"
  WF_SHA   = "91acc6ce02ad7f58587495c99a00af6a2f992611"

  WF_SOURCES = [] of String

  def self.wf_source(content : String) : String
    path = File.join(Dir.tempdir, "gitorules-wf-#{rand(1_000_000_000)}-#{WF_SOURCES.size}.yml")
    File.write(path, content)
    WF_SOURCES << path
    path
  end

  def self.wf_config(source : String, key : String = "ci.yml") : Config
    entry = WorkflowConfig.new
    entry.source = source
    config = Config.new
    config.workflows = {key => entry}
    config
  end

  def self.wf_contents_body(content : String, sha : String) : String
    encoded = Base64.strict_encode(content)
    %({"type":"file","encoding":"base64","size":#{content.bytesize},"name":"ci.yml","path":".github/workflows/ci.yml","content":"#{encoded}","sha":"#{sha}"})
  end

  describe WorkflowResource do
    client = GitHubClient.new(WF_TOKEN)
    resource = WorkflowResource.new(client)

    before_each do
      WebMock.reset
    end

    after_each do
      WF_SOURCES.each { |p| File.delete(p) if File.exists?(p) }
      WF_SOURCES.clear
    end

    describe ".target_path" do
      it "prefixes bare filenames" do
        WorkflowResource.target_path("ci.yml").should eq ".github/workflows/ci.yml"
      end

      it "keeps prefixed paths as-is" do
        WorkflowResource.target_path(".github/workflows/ci.yml").should eq ".github/workflows/ci.yml"
      end
    end

    describe ".valid_target?" do
      it "accepts yml files under workflows dir" do
        WorkflowResource.valid_target?(".github/workflows/ci.yml").should be_true
      end

      it "accepts yaml extension" do
        WorkflowResource.valid_target?(".github/workflows/ci.yaml").should be_true
      end

      it "rejects path traversal" do
        WorkflowResource.valid_target?(".github/workflows/../evil.yml").should be_false
      end

      it "rejects nested paths" do
        WorkflowResource.valid_target?(".github/workflows/sub/ci.yml").should be_false
      end

      it "rejects wrong extension" do
        WorkflowResource.valid_target?(".github/workflows/evil.sh").should be_false
      end

      it "rejects paths outside workflows dir" do
        WorkflowResource.valid_target?(".github/evil.yml").should be_false
      end
    end

    describe ".blob_sha" do
      it "matches the git blob sha" do
        WorkflowResource.blob_sha(WF_LOCAL).should eq WF_SHA
      end

      it "differs for different content" do
        WorkflowResource.blob_sha("other\n").should_not eq WF_SHA
      end
    end

    describe "#validate!" do
      it "accepts allowed targets" do
        entry = WorkflowConfig.new
        entry.source = "templates/ci.yml"
        resource.validate!({"ci.yml" => entry})
      end

      it "raises WorkflowError for disallowed targets" do
        entry = WorkflowConfig.new
        entry.source = "templates/evil.sh"
        expect_raises(WorkflowError, /only .github\/workflows\/\*\.yml/) do
          resource.validate!({"evil.sh" => entry})
        end
      end
    end

    describe "sync via Engine" do
      it "skips update when sha matches and performs zero PUTs" do
        src = Gitorules.wf_source(WF_LOCAL)
        engine = Engine.new(client, Gitorules.wf_config(src))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")
        WebMock.stub(:get, WF_URL)
          .to_return(body: Gitorules.wf_contents_body(WF_LOCAL, WF_SHA))
        put_stub = WebMock.stub(:put, /contents\//)

        io = IO::Memory.new
        engine.apply([WF_REPO], dry_run: false, io: io)
        put_stub.calls.should eq 0
        io.to_s.should_not contain("Updated workflow")
        io.to_s.should_not contain("Created workflow")
      end

      it "updates on sha mismatch" do
        old = "old content\n"
        src = Gitorules.wf_source(WF_LOCAL)
        engine = Engine.new(client, Gitorules.wf_config(src))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")
        WebMock.stub(:get, WF_URL)
          .to_return(body: Gitorules.wf_contents_body(old, WorkflowResource.blob_sha(old)))
        put_stub = WebMock.stub(:put, WF_URL)
          .to_return(body: %({"content":{"sha":"newsha"}}))

        io = IO::Memory.new
        engine.apply([WF_REPO], dry_run: false, io: io)
        put_stub.calls.should eq 1
        io.to_s.should contain("Updated workflow '.github/workflows/ci.yml'")
      end

      it "creates missing files on 404" do
        src = Gitorules.wf_source(WF_LOCAL)
        engine = Engine.new(client, Gitorules.wf_config(src))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")
        WebMock.stub(:get, WF_URL)
          .to_return(status: 404, body: %({"message":"Not found"}))
        put_stub = WebMock.stub(:put, WF_URL)
          .to_return(status: 201, body: %({"content":{"sha":"newsha"}}))

        io = IO::Memory.new
        engine.apply([WF_REPO], dry_run: false, io: io)
        put_stub.calls.should eq 1
        io.to_s.should contain("Created workflow '.github/workflows/ci.yml'")
      end

      it "rejects disallowed targets before any write" do
        engine = Engine.new(client, Gitorules.wf_config("templates/evil.sh", "evil.sh"))
        put_stub = WebMock.stub(:put, /contents\//)

        io = IO::Memory.new
        expect_raises(WorkflowError, /only .github\/workflows\/\*\.yml/) do
          engine.apply([WF_REPO], dry_run: false, io: io)
        end
        put_stub.calls.should eq 0
      end

      it "dry-run performs zero PUTs" do
        old = "old content\n"
        src = Gitorules.wf_source(WF_LOCAL)
        engine = Engine.new(client, Gitorules.wf_config(src))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")
        WebMock.stub(:get, WF_URL)
          .to_return(body: Gitorules.wf_contents_body(old, WorkflowResource.blob_sha(old)))
        put_stub = WebMock.stub(:put, /contents\//)

        io = IO::Memory.new
        engine.apply([WF_REPO], dry_run: true, io: io)
        put_stub.calls.should eq 0
        io.to_s.should contain("Would update workflow '.github/workflows/ci.yml'")
      end

      it "reports missing sources as repo errors" do
        engine = Engine.new(client, Gitorules.wf_config("/nonexistent/missing.yml"))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")
        put_stub = WebMock.stub(:put, /contents\//)

        io = IO::Memory.new
        engine.apply([WF_REPO], dry_run: false, io: io)
        put_stub.calls.should eq 0
        io.to_s.should contain("Error")
        io.to_s.should contain("1 error(s)")
      end

      it "shows workflow changes in diff without writing" do
        old = "old content\n"
        src = Gitorules.wf_source(WF_LOCAL)
        engine = Engine.new(client, Gitorules.wf_config(src))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")
        WebMock.stub(:get, WF_URL)
          .to_return(body: Gitorules.wf_contents_body(old, WorkflowResource.blob_sha(old)))
        put_stub = WebMock.stub(:put, /contents\//)

        io = IO::Memory.new
        engine.diff([WF_REPO], io: io)
        put_stub.calls.should eq 0
        io.to_s.should contain("Update workflow '.github/workflows/ci.yml'")
      end
    end

    describe "config" do
      it "parses workflows from YAML" do
        config = Config.from_yaml("org: unurgunite\nrepos:\n  - docscribe\nworkflows:\n  ci.yml:\n    source: templates/ci.yml\n")
        workflows = config.workflows_for("unurgunite/docscribe")
        workflows.should_not be_nil
        workflows.try(&.["ci.yml"].source).should eq "templates/ci.yml"
      end

      it "resolves per-org workflows" do
        config = Config.from_yaml("orgs:\n  unurgunite:\n    repos:\n      - docscribe\n    workflows:\n      ci.yml:\n        source: templates/ci.yml\n")
        config.workflows_for("unurgunite/docscribe").should_not be_nil
        config.workflows_for("other/repo").should be_nil
      end
    end

    describe "GitHubClient contents API" do
      it "reads content and sha" do
        wrapped = "#{Base64.strict_encode(WF_LOCAL)}\\n"
        body = %({"type":"file","encoding":"base64","size":22,"name":"ci.yml","path":".github/workflows/ci.yml","content":"#{wrapped}","sha":"#{WF_SHA}"})
        WebMock.stub(:get, WF_URL).to_return(body: body)

        remote = client.get_contents(WF_REPO, ".github/workflows/ci.yml")
        remote.should_not be_nil
        remote.try(&.[:sha]).should eq WF_SHA
        remote.try(&.[:content]).should eq WF_LOCAL
      end

      it "returns nil on 404" do
        WebMock.stub(:get, WF_URL).to_return(status: 404, body: %({"message":"Not found"}))

        client.get_contents(WF_REPO, ".github/workflows/ci.yml").should be_nil
      end

      it "writes base64 content with sha on update" do
        sent_body = ""
        WebMock.stub(:put, WF_URL).to_return do |req|
          sent_body = WebMock.body(req).to_s
          HTTP::Client::Response.new(200, body: %({"content":{"sha":"newsha"}}), headers: HTTP::Headers{"Content-Type" => "application/json"})
        end

        client.put_contents(WF_REPO, ".github/workflows/ci.yml", WF_LOCAL, WF_SHA, "Sync test")
        sent_body.should contain(Base64.strict_encode(WF_LOCAL))
        sent_body.should contain(WF_SHA)
      end
    end

    describe "CLI" do
      it "exits 2 on disallowed workflow targets" do
        config_yaml = "org: unurgunite\nrepos:\n  - unurgunite/docscribe\nworkflows:\n  evil.sh:\n    source: templates/evil.sh\n"
        path = File.join(Dir.tempdir, "gitorules-wf-cli-#{rand(1_000_000_000)}.yml")
        File.write(path, config_yaml)

        CLI.run(["--token", "test", "--config", path, "diff", "--repo", WF_REPO]).should eq 2
      ensure
        File.delete(path) if path && File.exists?(path)
      end
    end
  end
end
