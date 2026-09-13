require "./spec_helper"
require "json"

module Gitorules
  describe WorkflowChecks do
    describe ".produced_checks" do
      it "returns plain check names without matrix" do
        warnings = [] of String
        content = <<-YAML
          name: CI
          on: [push]
          jobs:
            build:
              runs-on: ubuntu-latest
              steps:
                - run: echo hi
          YAML
        WorkflowChecks.produced_checks(content, "ci.yml", "templates/ci.yml", warnings).should eq ["CI / build"]
        warnings.should be_empty
      end

      it "expands single-axis maps to concrete names" do
        warnings = [] of String
        content = <<-YAML
          name: CI
          on: [push]
          jobs:
            test:
              runs-on: ubuntu-latest
              strategy:
                matrix:
                  node-version: [20, 22, 24]
              steps:
                - run: echo hi
          YAML
        produced = WorkflowChecks.produced_checks(content, "ci.yml", "templates/ci.yml", warnings)
        produced.sort.should eq ["CI / test (20)", "CI / test (22)", "CI / test (24)"]
        warnings.should be_empty
      end

      it "expands multi-axis maps as a cartesian product" do
        warnings = [] of String
        content = <<-YAML
          name: VSCode CI
          on: [push]
          jobs:
            test:
              runs-on: ubuntu-latest
              strategy:
                matrix:
                  node-version: [18, 20]
                  vscode-version: ["stable", "insiders"]
              steps:
                - run: echo hi
          YAML
        produced = WorkflowChecks.produced_checks(content, "vscode-ci.yml", "templates/vscode-ci.yml", warnings)
        produced.sort.should eq [
          "VSCode CI / test (18, insiders)",
          "VSCode CI / test (18, stable)",
          "VSCode CI / test (20, insiders)",
          "VSCode CI / test (20, stable)",
        ]
        warnings.should be_empty
      end

      it "expands include lists" do
        warnings = [] of String
        content = <<-YAML
          name: CI
          on: [push]
          jobs:
            test:
              runs-on: ubuntu-latest
              strategy:
                matrix:
                  include:
                    - ruby: "3.1"
                      os: ubuntu-latest
                    - ruby: "3.2"
                      os: macos-latest
              steps:
                - run: echo hi
          YAML
        produced = WorkflowChecks.produced_checks(content, "ci.yml", "templates/ci.yml", warnings)
        produced.sort.should eq ["CI / test (3.1, ubuntu-latest)", "CI / test (3.2, macos-latest)"]
        warnings.should be_empty
      end

      it "falls back to plain job name with warning on unknown shapes" do
        warnings = [] of String
        content = <<-YAML
          name: CI
          on: [push]
          jobs:
            test:
              runs-on: ubuntu-latest
              strategy:
                matrix: "oops"
              steps:
                - run: echo hi
          YAML
        produced = WorkflowChecks.produced_checks(content, "ci.yml", "templates/ci.yml", warnings)
        produced.should eq ["CI / test"]
        warnings.size.should eq 1
        warnings.first.should contain "unknown matrix shape"
        warnings.first.should contain "CI / test"
      end

      it "falls back with warning when axis values are not lists" do
        warnings = [] of String
        content = <<-YAML
          name: CI
          on: [push]
          jobs:
            test:
              runs-on: ubuntu-latest
              strategy:
                matrix:
                  ruby: "3.1"
              steps:
                - run: echo hi
          YAML
        produced = WorkflowChecks.produced_checks(content, "ci.yml", "templates/ci.yml", warnings)
        produced.should eq ["CI / test"]
        warnings.size.should eq 1
        warnings.first.should contain "unknown matrix shape"
      end
    end
  end

  describe "consistency gate" do
    it "fails lint on stale checks with the exact error format" do
      template = File.join(Dir.tempdir, "verify-stale-tmpl-#{Random.rand(100000)}.yml")
      File.write(template, "name: CI\non: [push]\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n")
      config = <<-YAML
        org: testorg
        repos:
          - myrepo
        rules:
          default_branch:
            merge: only
            checks:
              - "check / check"
        workflows:
          ci.yml:
            source: #{template}
        YAML
      result = Linter.lint_content(config, ".gitorules.yml")
      result.errors.size.should eq 1
      message = result.errors.first
      message.should contain "check / check"
      message.should contain "rules.default_branch.checks"
      message.should contain "rename the check or update the template"
      message.should contain "CI / build"
      message.should contain "Produced checks"
    ensure
      File.delete(template) if template && File.exists?(template)
    end

    it "warns but does not fail on extra jobs" do
      template = File.join(Dir.tempdir, "verify-extra-tmpl-#{Random.rand(100000)}.yml")
      File.write(template, "name: CI\non: [push]\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n  extra:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n")
      config = <<-YAML
        org: testorg
        repos:
          - myrepo
        rules:
          default_branch:
            merge: only
            checks:
              - "CI / build"
        workflows:
          ci.yml:
            source: #{template}
        YAML
      result = Linter.lint_content(config, ".gitorules.yml")
      result.errors.should be_empty
      result.warnings.any?(&.includes?("CI / extra")).should be_true
    ensure
      File.delete(template) if template && File.exists?(template)
    end

    it "passes clean ruby fixtures" do
      template = File.join(Dir.tempdir, "verify-ruby-#{Random.rand(100000)}.yml")
      File.write(template, "name: CI\non: [push]\njobs:\n  test:\n    runs-on: ubuntu-latest\n    strategy:\n      matrix:\n        ruby: [\"3.1\", \"3.2\", \"3.3\", \"3.4\"]\n    steps:\n      - run: echo hi\n")
      config = <<-YAML
        org: testorg
        repos:
          - myrepo
        rules:
          default_branch:
            merge: only
            checks:
              - "CI / test (3.1)"
              - "CI / test (3.2)"
              - "CI / test (3.3)"
              - "CI / test (3.4)"
        workflows:
          ci.yml:
            source: #{template}
        YAML
      result = Linter.lint_content(config, ".gitorules.yml")
      result.errors.should be_empty
    ensure
      File.delete(template) if template && File.exists?(template)
    end

    it "passes clean crystal fixtures" do
      template = File.join(Dir.tempdir, "verify-crystal-#{Random.rand(100000)}.yml")
      File.write(template, "name: CI\non: [push]\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo build\n  test:\n    runs-on: ubuntu-latest\n    strategy:\n      matrix:\n        crystal: [\"1.20.0\", \"1.21.0\"]\n    steps:\n      - run: echo test\n")
      config = <<-YAML
        org: testorg
        repos:
          - myrepo
        rules:
          default_branch:
            merge: only
            checks:
              - "CI / build"
              - "CI / test (1.20.0)"
              - "CI / test (1.21.0)"
        workflows:
          ci.yml:
            source: #{template}
        YAML
      result = Linter.lint_content(config, ".gitorules.yml")
      result.errors.should be_empty
    ensure
      File.delete(template) if template && File.exists?(template)
    end

    it "passes clean node fixtures" do
      template = File.join(Dir.tempdir, "verify-node-#{Random.rand(100000)}.yml")
      File.write(template, "name: CI\non: [push]\njobs:\n  test:\n    runs-on: ubuntu-latest\n    strategy:\n      matrix:\n        node-version: [20, 22, 24]\n    steps:\n      - run: echo hi\n")
      config = <<-YAML
        org: testorg
        repos:
          - myrepo
        rules:
          default_branch:
            merge: only
            checks:
              - "CI / test (20)"
              - "CI / test (22)"
              - "CI / test (24)"
        workflows:
          ci.yml:
            source: #{template}
        YAML
      result = Linter.lint_content(config, ".gitorules.yml")
      result.errors.should be_empty
    ensure
      File.delete(template) if template && File.exists?(template)
    end

    it "skips scopes without workflows" do
      config = <<-YAML
        org: testorg
        repos:
          - myrepo
        rules:
          default_branch:
            merge: only
            checks:
              - "check / check"
        YAML
      result = Linter.lint_content(config, ".gitorules.yml")
      result.errors.should be_empty
    end
  end

  describe Verifier do
    it "prints a text report per scope" do
      template = File.join(Dir.tempdir, "verify-text-#{Random.rand(100000)}.yml")
      File.write(template, "name: CI\non: [push]\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n")
      config = <<-YAML
        org: testorg
        repos:
          - myrepo
        rules:
          default_branch:
            merge: only
            checks:
              - "check / check"
        workflows:
          ci.yml:
            source: #{template}
        YAML
      io = IO::Memory.new
      err = IO::Memory.new
      code = Verifier.verify_content(config, ".gitorules.yml", Dir.current, nil, false, io, err)
      code.should eq 2
      io.to_s.should contain "Scope: default"
      io.to_s.should contain "check / check"
      io.to_s.should contain "CI / build"
      io.to_s.should contain "Missing (1)"
    ensure
      File.delete(template) if template && File.exists?(template)
    end

    it "prints machine-readable JSON with --json" do
      template = File.join(Dir.tempdir, "verify-json-#{Random.rand(100000)}.yml")
      File.write(template, "name: CI\non: [push]\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n")
      config = <<-YAML
        org: testorg
        repos:
          - myrepo
        rules:
          default_branch:
            merge: only
            checks:
              - "check / check"
        workflows:
          ci.yml:
            source: #{template}
        YAML
      io = IO::Memory.new
      code = Verifier.verify_content(config, ".gitorules.yml", Dir.current, nil, true, io, IO::Memory.new)
      code.should eq 2
      arr = JSON.parse(io.to_s).as_a
      arr.size.should eq 1
      arr[0]["scope"].to_s.should eq "default"
      arr[0]["required"].as_a.map(&.to_s).should eq ["check / check"]
      arr[0]["produced"].as_a.map(&.to_s).should eq ["CI / build"]
      arr[0]["missing"].as_a.map(&.to_s).should eq ["check / check"]
      arr[0]["extra"].as_a.map(&.to_s).should eq ["CI / build"]
      arr[0]["ok"].should be_false
    ensure
      File.delete(template) if template && File.exists?(template)
    end

    it "returns 0 for clean scopes in text and JSON" do
      template = File.join(Dir.tempdir, "verify-clean-#{Random.rand(100000)}.yml")
      File.write(template, "name: CI\non: [push]\njobs:\n  test:\n    runs-on: ubuntu-latest\n    strategy:\n      matrix:\n        node-version: [20, 22]\n    steps:\n      - run: echo hi\n")
      config = <<-YAML
        org: testorg
        repos:
          - myrepo
        rules:
          default_branch:
            merge: only
            checks:
              - "CI / test (20)"
              - "CI / test (22)"
        workflows:
          ci.yml:
            source: #{template}
        YAML
      Verifier.verify_content(config, ".gitorules.yml", Dir.current, nil, false, IO::Memory.new, IO::Memory.new).should eq 0
      json_io = IO::Memory.new
      Verifier.verify_content(config, ".gitorules.yml", Dir.current, nil, true, json_io, IO::Memory.new).should eq 0
      JSON.parse(json_io.to_s).as_a[0]["ok"].should be_true
    ensure
      File.delete(template) if template && File.exists?(template)
    end

    it "verify command exits 2 on stale checks without a token" do
      template = File.join(Dir.tempdir, "verify-cli-stale-#{Random.rand(100000)}.yml")
      File.write(template, "name: CI\non: [push]\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n")
      path = File.join(Dir.tempdir, "verify-cli-#{Random.rand(100000)}.yml")
      File.write(path, "org: testorg\nrepos:\n  - myrepo\nrules:\n  default_branch:\n    merge: only\n    checks:\n      - \"check / check\"\nworkflows:\n  ci.yml:\n    source: #{template}\n")
      saved = ENV["GITHUB_TOKEN"]?
      ENV.delete("GITHUB_TOKEN")
      CLI.run(["verify", "--config", path]).should eq 2
      CLI.run(["scope", "verify", "--config", path]).should eq 2
    ensure
      File.delete(template) if template && File.exists?(template)
      File.delete(path) if path && File.exists?(path)
      ENV["GITHUB_TOKEN"] = saved if saved
    end

    it "verify command exits 0 on clean config" do
      template = File.join(Dir.tempdir, "verify-cli-clean-tmpl-#{Random.rand(100000)}.yml")
      File.write(template, "name: CI\non: [push]\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n")
      path = File.join(Dir.tempdir, "verify-cli-clean-#{Random.rand(100000)}.yml")
      File.write(path, "org: testorg\nrepos:\n  - myrepo\nrules:\n  default_branch:\n    merge: only\n    checks:\n      - \"CI / build\"\nworkflows:\n  ci.yml:\n    source: #{template}\n")
      CLI.run(["verify", "--config", path]).should eq 0
    ensure
      File.delete(template) if template && File.exists?(template)
      File.delete(path) if path && File.exists?(path)
    end
  end
end
