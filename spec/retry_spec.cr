require "./spec_helper"

module Gitorules
  describe "GitHubClient retry with backoff" do
    client = GitHubClient.new("test-token")

    before_each do
      WebMock.reset
    end

    it "retries on 429 then succeeds" do
      calls = 0
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
        .to_return do |_req|
          calls += 1
          if calls == 1
            HTTP::Client::Response.new(429, body: "rate limited", headers: HTTP::Headers{"Content-Type" => "application/json"})
          else
            HTTP::Client::Response.new(200, body: "[]", headers: HTTP::Headers{"Content-Type" => "application/json"})
          end
        end

      result = client.list_rulesets("unurgunite/docscribe")
      result.should eq [] of Ruleset
      calls.should eq 2
    end

    it "retries on 500 then succeeds" do
      calls = 0
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
        .to_return do |_req|
          calls += 1
          if calls < 3
            HTTP::Client::Response.new(500, body: "oops", headers: HTTP::Headers.new)
          else
            HTTP::Client::Response.new(200, body: "[]", headers: HTTP::Headers.new)
          end
        end

      result = client.list_rulesets("unurgunite/docscribe")
      result.should eq [] of Ruleset
      calls.should eq 3
    end

    it "gives up after max retries and raises" do
      calls = 0
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
        .to_return do |_req|
          calls += 1
          HTTP::Client::Response.new(500, body: "boom", headers: HTTP::Headers.new)
        end

      expect_raises(Exception, "HTTP 500") do
        client.list_rulesets("unurgunite/docscribe")
      end
      calls.should eq(GitHubClient::MAX_RETRIES + 1)
    end

    it "honors Retry-After header without failing" do
      calls = 0
      WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
        .to_return do |_req|
          calls += 1
          if calls == 1
            HTTP::Client::Response.new(429, body: "slow down", headers: HTTP::Headers{"Retry-After" => "0"})
          else
            HTTP::Client::Response.new(200, body: "[]", headers: HTTP::Headers.new)
          end
        end

      result = client.list_rulesets("unurgunite/docscribe")
      result.should eq [] of Ruleset
      calls.should eq 2
    end
  end
end
