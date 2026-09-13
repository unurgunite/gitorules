require "./spec_helper"

module Gitorules
  describe "init --template" do
    token = "test-token"
    repo = "unurgunite/fresh-repo"

    before_each do
      WebMock.reset
    end

    it "writes only allowlisted paths for every template" do
      %w[ruby node crystal gradle].each do |template|
        files = ConfigGenerator.template_files(template)
        files.should_not be_nil
        if map = files
          map.each_key do |target|
            FileSync.allowed?(target).should be_true
          end
        end
      end
    end

    it "scaffolds the ruby template via the API" do
      client = GitHubClient.new(token)
      generator = ConfigGenerator.new(client)
      file_map = ConfigGenerator.template_files("ruby") || {} of String => String
      file_map.empty?.should be_false

      file_map.each do |target, _content|
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/fresh-repo/contents/#{target}")
          .to_return(status: 404, body: %({"message":"Not found"}))
      end
      put_stub = WebMock.stub(:put, /contents\//)
        .to_return(status: 201, body: %({"content":{"sha":"newsha"}}))

      io = IO::Memory.new
      generator.scaffold_template("ruby", repo, io)
      put_stub.calls.should eq file_map.size
      file_map.each_key do |target|
        io.to_s.should contain(target)
      end
    end

    it "skips up-to-date template files with zero PUTs" do
      client = GitHubClient.new(token)
      generator = ConfigGenerator.new(client)
      file_map = ConfigGenerator.template_files("node") || {} of String => String

      file_map.each do |target, content|
        sha = WorkflowResource.blob_sha(content)
        encoded = Base64.strict_encode(content)
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/fresh-repo/contents/#{target}")
          .to_return(body: %({"type":"file","encoding":"base64","content":"#{encoded}","sha":"#{sha}"}))
      end
      put_stub = WebMock.stub(:put, /contents\//)

      io = IO::Memory.new
      generator.scaffold_template("node", repo, io)
      put_stub.calls.should eq 0
      io.to_s.should contain("up to date")
    end

    it "raises on unknown templates" do
      client = GitHubClient.new(token)
      generator = ConfigGenerator.new(client)
      expect_raises(Exception, /Unknown template/) do
        generator.scaffold_template("cobol", repo, IO::Memory.new)
      end
    end

    it "CLI rejects unknown templates with exit 2" do
      CLI.run(["--token", "test", "init", "--repo", repo, "--template", "cobol"]).should eq 2
    end

    it "CLI requires --repo for init --template" do
      CLI.run(["--token", "test", "init", "--template", "ruby"]).should eq 2
    end
  end
end
