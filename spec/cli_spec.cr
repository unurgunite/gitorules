require "./spec_helper"

module Gitorules
  describe CLI do
    describe ".run" do
      it "prints version and exits 0 on --version" do
        status = CLI.run(["--version"])
        status.should eq(0)
      end

      it "prints help and exits 0 on --help" do
        status = CLI.run(["--help"])
        status.should eq(0)
      end

      it "prints help and exits 0 on -h" do
        status = CLI.run(["-h"])
        status.should eq(0)
      end

      it "returns 1 when GITHUB_TOKEN not set and no --token" do
        status = CLI.run(["status"])
        status.should eq(1)
      end

      it "returns 1 when config file not found" do
        status = CLI.run(["--token", "test", "--config", File.join(Dir.tempdir, "nonexistent.yml")])
        status.should eq(1)
      end
    end
  end
end
