require "./spec_helper"

module Gitorules
  describe "list_repos pagination" do
    client = GitHubClient.new("test-token")

    before_each do
      WebMock.reset
    end

    it "follows Link pagination to collect 150 repos" do
      page1_repos = (1..100).map { |i| %({"name": "repo-%03d"}) % i }.join(",")
      page2_repos = (101..150).map { |i| %({"name": "repo-%03d"}) % i }.join(",")

      WebMock.stub(:get, "https://api.github.com/orgs/unurgunite/repos?per_page=100&type=owner")
        .to_return(
          body: "[#{page1_repos}]",
          headers: {
            "Content-Type" => "application/json",
            "Link"         => %(<https://api.github.com/orgs/unurgunite/repos?per_page=100&type=owner&page=2>; rel="next", <https://api.github.com/orgs/unurgunite/repos?per_page=100&type=owner&page=2>; rel="last"),
          }
        )

      WebMock.stub(:get, "https://api.github.com/orgs/unurgunite/repos?per_page=100&type=owner&page=2")
        .to_return(body: "[#{page2_repos}]", headers: {"Content-Type" => "application/json"})

      result = client.list_repos("unurgunite")
      result.size.should eq 150
      result.first.should eq "repo-001"
      result[99].should eq "repo-100"
      result[100].should eq "repo-101"
      result.last.should eq "repo-150"
    end

    it "returns single page when no Link header" do
      WebMock.stub(:get, "https://api.github.com/orgs/unurgunite/repos?per_page=100&type=owner")
        .to_return(body: %([{"name": "a"}, {"name": "b"}]))

      result = client.list_repos("unurgunite")
      result.should eq ["a", "b"]
    end
  end
end
