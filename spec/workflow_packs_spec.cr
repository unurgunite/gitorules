require "./spec_helper"
require "base64"
require "yaml"

module Gitorules
  TEMPLATES_ROOT = File.expand_path(File.join(__DIR__, "..", "templates"))

  def self.read_pack(path : String) : String
    File.read(File.join(TEMPLATES_ROOT, path))
  end

  describe "workflow packs" do
    describe "templates/gradle/ci.yml" do
      it "is valid YAML with a stable build job" do
        content = Gitorules.read_pack("gradle/ci.yml")
        parsed = YAML.parse(content)
        parsed["name"].as_s.should eq "CI"
        build = parsed["jobs"]["build"]
        build["runs-on"].as_s.should eq "ubuntu-latest"
        steps = build["steps"].as_a
        steps.should_not be_empty
      end

      it "contains the required IntelliJ plugin steps" do
        content = Gitorules.read_pack("gradle/ci.yml")
        content.should contain "actions/checkout@v4"
        content.should contain "actions/setup-java@v4"
        content.should contain "temurin"
        content.should contain "21"
        content.should contain "crystal-lang/install-crystal@v1"
        content.should contain "gradle/actions/setup-gradle@v4"
        content.should contain "Check version consistency"
        content.should contain "gradle.properties"
        content.should contain "CHANGELOG.md"
        content.should contain "./gradlew test"
        content.should contain "verifyPlugin"
        content.should contain "buildPlugin"
        content.should contain "actions/upload-artifact@v4"
      end

      it "pins the Crystal version" do
        content = Gitorules.read_pack("gradle/ci.yml")
        content.should contain "crystal:"
      end

      it "exposes the extra-steps anchor" do
        content = Gitorules.read_pack("gradle/ci.yml")
        content.should contain "# gitorules:extra-steps"
      end

      it "uses a single build job for stable check contexts" do
        parsed = YAML.parse(Gitorules.read_pack("gradle/ci.yml"))
        jobs = parsed["jobs"].as_h
        jobs.size.should eq 1
        jobs.keys.first.as_s.should eq "build"
      end
    end

    describe "templates/python/ci.yml" do
      it "is valid YAML with setup-python matrix and pytest" do
        content = Gitorules.read_pack("python/ci.yml")
        parsed = YAML.parse(content)
        parsed["name"].as_s.should eq "CI"
        build = parsed["jobs"]["build"]
        build["runs-on"].as_s.should eq "ubuntu-latest"
        content.should contain "actions/setup-python@v5"
        content.should contain "python-version"
        content.should contain "cache: pip"
        content.should contain "pytest"
      end

      it "exposes the extra-steps anchor" do
        Gitorules.read_pack("python/ci.yml").should contain "# gitorules:extra-steps"
      end
    end

    describe "templates/shell/ci.yml" do
      it "is valid YAML with shellcheck and shell test skeleton" do
        content = Gitorules.read_pack("shell/ci.yml")
        parsed = YAML.parse(content)
        parsed["name"].as_s.should eq "CI"
        build = parsed["jobs"]["build"]
        build["runs-on"].as_s.should eq "ubuntu-latest"
        content.should contain "shellcheck"
        content.should contain "bats"
      end

      it "exposes the extra-steps anchor" do
        Gitorules.read_pack("shell/ci.yml").should contain "# gitorules:extra-steps"
      end
    end

    describe "extra-steps example" do
      it "is a valid YAML step list" do
        content = Gitorules.read_pack("gradle/extra-steps.example.yml")
        parsed = YAML.parse(content)
        steps = parsed.as_a
        steps.should_not be_empty
        steps.first.as_h.has_key?(YAML::Any.new("name")).should be_true
      end
    end
  end

  describe WorkflowResource do
    describe ".apply_extra_steps" do
      it "appends extra steps after the anchor and keeps the base intact" do
        base = "jobs:\n  build:\n    steps:\n      - uses: actions/checkout@v4\n      # gitorules:extra-steps\n      - name: Test\n        run: ./gradlew test\n"
        extra = "- name: Check change notes\n  run: ./gradlew checkChangeNotes\n"
        resolved = WorkflowResource.apply_extra_steps(base, extra)
        resolved.should contain "actions/checkout@v4"
        resolved.should contain "./gradlew test"
        resolved.should contain "Check change notes"
        resolved.should contain "# gitorules:extra-steps"
        # Base lines stay in order around the insertion.
        checkout_idx = resolved.index("actions/checkout@v4") || -1
        extra_idx = resolved.index("Check change notes") || -1
        test_idx = resolved.index("./gradlew test") || -1
        checkout_idx.should be >= 0
        (checkout_idx < extra_idx).should be_true
        (extra_idx < test_idx).should be_true
      end

      it "supports a custom anchor" do
        base = "steps:\n  # my-anchor\n  - run: base\n"
        extra = "- run: extra\n"
        resolved = WorkflowResource.apply_extra_steps(base, extra, "my-anchor")
        resolved.should contain "extra"
        anchor_idx = resolved.index("my-anchor") || -1
        extra_idx = resolved.index("extra") || -1
        (extra_idx > anchor_idx).should be_true
      end

      it "returns the base unchanged for blank extra content" do
        base = "steps:\n  # gitorules:extra-steps\n  - run: base\n"
        WorkflowResource.apply_extra_steps(base, "  \n").should eq base
      end

      it "raises WorkflowError for an unknown anchor" do
        base = "steps:\n  - run: base\n"
        extra = "- run: extra\n"
        expect_raises(WorkflowError, /Unknown extra_steps anchor/) do
          WorkflowResource.apply_extra_steps(base, extra)
        end
      end

      it "raises WorkflowError when extra steps are not a YAML list" do
        base = "steps:\n  # gitorules:extra-steps\n  - run: base\n"
        expect_raises(WorkflowError, /YAML list/) do
          WorkflowResource.apply_extra_steps(base, "name: not-a-list\n")
        end
      end

      it "resolves the default anchor name" do
        entry = WorkflowConfig.new
        WorkflowResource.extra_anchor(entry).should eq "gitorules:extra-steps"
        entry.extra_steps_anchor = "  custom  "
        WorkflowResource.extra_anchor(entry).should eq "custom"
      end
    end

    describe "plan with extra_steps" do
      it "syncs resolved content containing the extra steps" do
        WebMock.reset
        client = GitHubClient.new("test-token")
        resource = WorkflowResource.new(client)

        base = "name: CI\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n      # gitorules:extra-steps\n      - run: base\n"
        extra = "- name: Check change notes\n  run: ./gradlew checkChangeNotes\n"
        base_path = File.join(Dir.tempdir, "gitorules-base-#{Random.rand(1_000_000_000)}.yml")
        extra_path = File.join(Dir.tempdir, "gitorules-extra-#{Random.rand(1_000_000_000)}.yml")
        File.write(base_path, base)
        File.write(extra_path, extra)

        entry = WorkflowConfig.new
        entry.source = base_path
        entry.extra_steps = extra_path

        url = "https://api.github.com/repos/unurgunite/docscribe/contents/.github/workflows/ci.yml"
        WebMock.stub(:get, url).to_return(status: 404, body: %({"message":"Not found"}))

        plans = resource.plan_repo("unurgunite/docscribe", {"ci.yml" => entry})
        plans.size.should eq 1
        plans.first.action.should eq "create"
        plans.first.content.should contain "Check change notes"
        plans.first.content.should contain "actions/checkout@v4"
      ensure
        File.delete(base_path) if base_path && File.exists?(base_path)
        File.delete(extra_path) if extra_path && File.exists?(extra_path)
        WebMock.reset
      end

      it "reports unchanged when the remote matches resolved content" do
        WebMock.reset
        client = GitHubClient.new("test-token")
        resource = WorkflowResource.new(client)

        base = "name: CI\njobs:\n  build:\n    steps:\n      - uses: actions/checkout@v4\n      # gitorules:extra-steps\n      - run: base\n"
        extra = "- run: extra\n"
        resolved = WorkflowResource.apply_extra_steps(base, extra)
        sha = WorkflowResource.blob_sha(resolved)

        base_path = File.join(Dir.tempdir, "gitorules-base-#{Random.rand(1_000_000_000)}.yml")
        extra_path = File.join(Dir.tempdir, "gitorules-extra-#{Random.rand(1_000_000_000)}.yml")
        File.write(base_path, base)
        File.write(extra_path, extra)

        entry = WorkflowConfig.new
        entry.source = base_path
        entry.extra_steps = extra_path

        encoded = Base64.strict_encode(resolved)
        url = "https://api.github.com/repos/unurgunite/docscribe/contents/.github/workflows/ci.yml"
        WebMock.stub(:get, url).to_return(body: %({"type":"file","encoding":"base64","content":"#{encoded}","sha":"#{sha}"}))

        plans = resource.plan_repo("unurgunite/docscribe", {"ci.yml" => entry})
        plans.first.action.should eq "unchanged"
      ensure
        File.delete(base_path) if base_path && File.exists?(base_path)
        File.delete(extra_path) if extra_path && File.exists?(extra_path)
        WebMock.reset
      end

      it "raises WorkflowError for an unknown anchor during planning" do
        WebMock.reset
        client = GitHubClient.new("test-token")
        resource = WorkflowResource.new(client)

        base_path = File.join(Dir.tempdir, "gitorules-base-#{Random.rand(1_000_000_000)}.yml")
        extra_path = File.join(Dir.tempdir, "gitorules-extra-#{Random.rand(1_000_000_000)}.yml")
        File.write(base_path, "steps:\n  - run: base\n")
        File.write(extra_path, "- run: extra\n")

        entry = WorkflowConfig.new
        entry.source = base_path
        entry.extra_steps = extra_path

        expect_raises(WorkflowError, /Unknown extra_steps anchor/) do
          resource.plan_repo("unurgunite/docscribe", {"ci.yml" => entry})
        end
      ensure
        File.delete(base_path) if base_path && File.exists?(base_path)
        File.delete(extra_path) if extra_path && File.exists?(extra_path)
        WebMock.reset
      end

      it "reports a missing extra_steps file as an error" do
        WebMock.reset
        client = GitHubClient.new("test-token")
        resource = WorkflowResource.new(client)

        base_path = File.join(Dir.tempdir, "gitorules-base-#{Random.rand(1_000_000_000)}.yml")
        File.write(base_path, "steps:\n  # gitorules:extra-steps\n")

        entry = WorkflowConfig.new
        entry.source = base_path
        entry.extra_steps = File.join(Dir.tempdir, "gitorules-missing-#{Random.rand(1_000_000_000)}.yml")

        expect_raises(Exception, /extra_steps not found/) do
          resource.plan_repo("unurgunite/docscribe", {"ci.yml" => entry})
        end
      ensure
        File.delete(base_path) if base_path && File.exists?(base_path)
        WebMock.reset
      end
    end

    describe "lint for workflows" do
      it "accepts a valid extra_steps entry" do
        base_path = File.join(Dir.tempdir, "gitorules-lint-base-#{Random.rand(1_000_000_000)}.yml")
        extra_path = File.join(Dir.tempdir, "gitorules-lint-extra-#{Random.rand(1_000_000_000)}.yml")
        File.write(base_path, "steps:\n  # gitorules:extra-steps\n  - run: base\n")
        File.write(extra_path, "- name: Extra\n  run: echo hi\n")
        result = Linter.lint_content(<<-YAML, "check.yml")
          org: test
          repos:
            - r
          rules:
            default_branch:
              merge: only
          workflows:
            ci.yml:
              source: #{base_path}
              extra_steps: #{extra_path}
          YAML
        result.errors.should be_empty
      ensure
        File.delete(base_path) if base_path && File.exists?(base_path)
        File.delete(extra_path) if extra_path && File.exists?(extra_path)
      end

      it "rejects an unknown anchor" do
        base_path = File.join(Dir.tempdir, "gitorules-lint-base-#{Random.rand(1_000_000_000)}.yml")
        extra_path = File.join(Dir.tempdir, "gitorules-lint-extra-#{Random.rand(1_000_000_000)}.yml")
        File.write(base_path, "steps:\n  - run: base\n")
        File.write(extra_path, "- name: Extra\n  run: echo hi\n")
        result = Linter.lint_content(<<-YAML, "check.yml")
          org: test
          repos:
            - r
          rules:
            default_branch:
              merge: only
          workflows:
            ci.yml:
              source: #{base_path}
              extra_steps: #{extra_path}
          YAML
        result.errors.any?(&.includes?("unknown anchor")).should be_true
      ensure
        File.delete(base_path) if base_path && File.exists?(base_path)
        File.delete(extra_path) if extra_path && File.exists?(extra_path)
      end

      it "rejects unknown workflow fields and invalid targets" do
        result = Linter.lint_content(<<-YAML, "check.yml")
          org: test
          repos:
            - r
          rules:
            default_branch:
              merge: only
          workflows:
            evil.sh:
              source: templates/evil.sh
          YAML
        result.errors.any?(&.includes?("invalid workflow target")).should be_true
      end
    end
  end
end
