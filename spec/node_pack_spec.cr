require "./spec_helper"
require "base64"
require "yaml"

module Gitorules
  NODE_REPO       = "unurgunite/docscribe"
  NODE_CI_URL     = "https://api.github.com/repos/unurgunite/docscribe/contents/.github/workflows/ci.yml"
  NODE_VSCODE_URL = "https://api.github.com/repos/unurgunite/docscribe/contents/.github/workflows/vscode-ci.yml"

  def self.node_template_path(name : String) : String
    File.join(__DIR__, "..", "templates", "node", name)
  end

  def self.node_contents_body(content : String, sha : String) : String
    encoded = Base64.strict_encode(content)
    %({"type":"file","encoding":"base64","size":#{content.bytesize},"name":"workflow.yml","path":".github/workflows/workflow.yml","content":"#{encoded}","sha":"#{sha}"})
  end

  def self.node_workflows(source : String, key : String) : Hash(String, WorkflowConfig)
    entry = WorkflowConfig.new
    entry.source = source
    {key => entry}
  end

  describe "Node CI template pack" do
    client = GitHubClient.new("test-token")
    resource = WorkflowResource.new(client)

    before_each do
      WebMock.reset
    end

    describe "templates/node/ci.yml" do
      it "pins workflow name, single test job and node matrix" do
        path = Gitorules.node_template_path("ci.yml")
        doc = YAML.parse(File.read(path))

        doc["name"].as_s.should eq "CI"
        jobs = doc["jobs"].as_h
        jobs.keys.map(&.as_s).should eq ["test"]

        job = doc["jobs"]["test"]
        job["runs-on"].as_s.should eq "ubuntu-latest"
        matrix = job["strategy"]["matrix"]["node-version"].as_a
        matrix.map(&.as_i).should eq [20, 22, 24]
      end

      it "uses npm ci with cache, eslint and typecheck" do
        content = File.read(Gitorules.node_template_path("ci.yml"))

        content.should contain "actions/checkout"
        content.should contain "actions/setup-node"
        content.should contain "cache: npm"
        content.should contain "npm ci"
        content.should contain "eslint"
        content.should contain "typecheck"
      end

      it "plans create for missing remote file" do
        source = Gitorules.node_template_path("ci.yml")
        workflows = Gitorules.node_workflows(source, "ci.yml")
        WebMock.stub(:get, NODE_CI_URL).to_return(status: 404, body: %({"message":"Not found"}))

        plans = resource.plan_repo(NODE_REPO, workflows)

        plans.size.should eq 1
        plans[0].action.should eq "create"
        plans[0].target.should eq ".github/workflows/ci.yml"
      end

      it "updates on sha mismatch" do
        old = "old content\n"
        source = Gitorules.node_template_path("ci.yml")
        workflows = Gitorules.node_workflows(source, "ci.yml")
        WebMock.stub(:get, NODE_CI_URL)
          .to_return(body: Gitorules.node_contents_body(old, WorkflowResource.blob_sha(old)))
        put_stub = WebMock.stub(:put, NODE_CI_URL)
          .to_return(body: %({"content":{"sha":"newsha"}}))

        plans = resource.sync_repo(NODE_REPO, workflows, dry_run: false)

        put_stub.calls.should eq 1
        plans[0].action.should eq "update"
      end

      it "skips write when sha matches" do
        local = File.read(Gitorules.node_template_path("ci.yml"))
        source = Gitorules.node_template_path("ci.yml")
        workflows = Gitorules.node_workflows(source, "ci.yml")
        WebMock.stub(:get, NODE_CI_URL)
          .to_return(body: Gitorules.node_contents_body(local, WorkflowResource.blob_sha(local)))
        put_stub = WebMock.stub(:put, /contents\//)

        plans = resource.sync_repo(NODE_REPO, workflows, dry_run: false)

        put_stub.calls.should eq 0
        plans[0].action.should eq "unchanged"
      end
    end

    describe "templates/node/vscode-ci.yml" do
      it "pins workflow name, single test job and both matrix axes" do
        path = Gitorules.node_template_path("vscode-ci.yml")
        doc = YAML.parse(File.read(path))

        doc["name"].as_s.should eq "VSCode CI"
        jobs = doc["jobs"].as_h
        jobs.keys.map(&.as_s).should eq ["test"]

        job = doc["jobs"]["test"]
        job["runs-on"].as_s.should eq "ubuntu-latest"
        matrix = job["strategy"]["matrix"]
        matrix["node-version"].as_a.map(&.as_i).should eq [18, 20, 22, 24]
        matrix["vscode-version"].as_a.map(&.as_s).should eq ["stable", "insiders"]
      end

      it "runs format, lint, typecheck, compile and xvfb tests with retry" do
        content = File.read(Gitorules.node_template_path("vscode-ci.yml"))

        content.should contain "actions/checkout"
        content.should contain "actions/setup-node"
        content.should contain "cache: npm"
        content.should contain "npm ci"
        content.should contain "npm run format:check"
        content.should contain "npm run lint"
        content.should contain "npm run typecheck"
        content.should contain "npm run compile"
        content.should contain "nick-fields/retry"
        content.should contain "timeout_minutes: 10"
        content.should contain "max_attempts: 2"
        content.should contain "xvfb-run -a npm test -- --vscode-version ${{ matrix.vscode-version }}"
      end

      it "plans create for missing remote file" do
        source = Gitorules.node_template_path("vscode-ci.yml")
        workflows = Gitorules.node_workflows(source, "vscode-ci.yml")
        WebMock.stub(:get, NODE_VSCODE_URL).to_return(status: 404, body: %({"message":"Not found"}))

        plans = resource.plan_repo(NODE_REPO, workflows)

        plans.size.should eq 1
        plans[0].action.should eq "create"
        plans[0].target.should eq ".github/workflows/vscode-ci.yml"
      end

      it "updates on sha mismatch" do
        old = "old content\n"
        source = Gitorules.node_template_path("vscode-ci.yml")
        workflows = Gitorules.node_workflows(source, "vscode-ci.yml")
        WebMock.stub(:get, NODE_VSCODE_URL)
          .to_return(body: Gitorules.node_contents_body(old, WorkflowResource.blob_sha(old)))
        put_stub = WebMock.stub(:put, NODE_VSCODE_URL)
          .to_return(body: %({"content":{"sha":"newsha"}}))

        plans = resource.sync_repo(NODE_REPO, workflows, dry_run: false)

        put_stub.calls.should eq 1
        plans[0].action.should eq "update"
      end

      it "skips write when sha matches" do
        local = File.read(Gitorules.node_template_path("vscode-ci.yml"))
        source = Gitorules.node_template_path("vscode-ci.yml")
        workflows = Gitorules.node_workflows(source, "vscode-ci.yml")
        WebMock.stub(:get, NODE_VSCODE_URL)
          .to_return(body: Gitorules.node_contents_body(local, WorkflowResource.blob_sha(local)))
        put_stub = WebMock.stub(:put, /contents\//)

        plans = resource.sync_repo(NODE_REPO, workflows, dry_run: false)

        put_stub.calls.should eq 0
        plans[0].action.should eq "unchanged"
      end
    end
  end
end
