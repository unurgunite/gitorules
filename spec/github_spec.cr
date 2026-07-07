require "./spec_helper"

module Gitorules
  TOKEN = "test-token"
  REPO  = "unurgunite/docscribe"
  ORG   = "unurgunite"

  describe GitHubClient do
    client = GitHubClient.new(TOKEN)

    describe "#list_rulesets" do
      it "returns an array of rulesets" do
        body = <<-JSON
          [
            {"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": []},
            {"id": 2, "name": "release", "enforcement": "active", "target": "branch", "rules": []}
          ]
          JSON

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: body, headers: {"Content-Type" => "application/json"})

        result = client.list_rulesets(REPO)
        result.size.should eq 2
        result[0].name.should eq "master"
        result[1].name.should eq "release"
      end
    end

    describe "#get_ruleset" do
      it "returns a single ruleset with rules" do
        body = <<-JSON
          {"id": 1, "name": "master", "enforcement": "active", "target": "branch",
           "rules": [{"type": "deletion"}, {"type": "pull_request", "parameters": {"allowed_merge_methods": ["merge"]}}]}
          JSON

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets/1")
          .to_return(body: body, headers: {"Content-Type" => "application/json"})

        result = client.get_ruleset(REPO, 1_i64)
        result.name.should eq "master"
        result.rules.size.should eq 2
        result.rules[0].type.should eq "deletion"
        result.rules[1].type.should eq "pull_request"
      end
    end

    describe "#create_ruleset" do
      it "creates and returns the new ruleset" do
        body = <<-JSON
          {"id": 42, "name": "release", "enforcement": "active", "target": "branch", "rules": []}
          JSON

        WebMock.stub(:post, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(status: 201, body: body, headers: {"Content-Type" => "application/json"})

        rs = Ruleset.new("release")
        result = client.create_ruleset(REPO, rs)
        result.id.should eq 42_i64
        result.name.should eq "release"
      end
    end

    describe "#update_ruleset" do
      it "replaces and returns the updated ruleset" do
        body = <<-JSON
          {"id": 1, "name": "master", "enforcement": "active", "target": "branch", "rules": []}
          JSON

        WebMock.stub(:put, "https://api.github.com/repos/unurgunite/docscribe/rulesets/1")
          .to_return(body: body, headers: {"Content-Type" => "application/json"})

        rs = Ruleset.new("master")
        result = client.update_ruleset(REPO, 1_i64, rs)
        result.id.should eq 1_i64
        result.name.should eq "master"
      end
    end

    describe "#list_repos" do
      it "returns repository names for an organization" do
        body = <<-JSON
          [{"name": "docscribe"}, {"name": "genius-api"}, {"name": "irb-autosuggestions"}]
          JSON

        WebMock.stub(:get, "https://api.github.com/orgs/unurgunite/repos?per_page=100&type=owner")
          .to_return(body: body, headers: {"Content-Type" => "application/json"})

        result = client.list_repos(ORG)
        result.should eq ["docscribe", "genius-api", "irb-autosuggestions"]
      end
    end

    describe "error handling" do
      it "raises on 404" do
        WebMock.reset
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/unknown/rulesets")
          .to_return(status: 404)

        expect_raises(Exception, "Not found") do
          client.list_rulesets("unurgunite/unknown")
        end
      end

      it "raises on 422" do
        WebMock.reset
        WebMock.stub(:post, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(status: 422, body: "name is missing")

        expect_raises(Exception, "Validation error") do
          client.create_ruleset(REPO, Ruleset.new(""))
        end
      end

      it "raises on 500" do
        WebMock.reset
        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(status: 500, body: "Internal Server Error")

        expect_raises(Exception, "HTTP 500") do
          client.list_rulesets(REPO)
        end
      end
    end

    describe "GitHub App auth" do
      app_id = "123456"
      installation_id = "789012"
      test_private_key = File.read("spec/fixtures/test_private_key.pem")

      before_each do
        WebMock.reset
      end

      it "exchanges JWT for installation token on init" do
        WebMock.stub(:post, "https://api.github.com/app/installations/789012/access_tokens")
          .to_return(body: %({"token": "inst_token_abc", "expires_at": "2027-01-01T00:00:00Z"}))

        app_client = GitHubClient.new(app_id, test_private_key, installation_id)
        app_client.token.should eq "inst_token_abc"
      end

      it "refreshes expired token on next API call" do
        call_count = 0
        WebMock.stub(:post, "https://api.github.com/app/installations/789012/access_tokens")
          .to_return do |_req|
            call_count += 1
            body = call_count == 1 ? %({"token": "inst_token_old", "expires_at": "2020-01-01T00:00:00Z"}) : %({"token": "inst_token_new", "expires_at": "2027-01-01T00:00:00Z"})
            HTTP::Client::Response.new(200, body: body, headers: HTTP::Headers{"Content-Type" => "application/json"})
          end

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .to_return(body: "[]")

        app_client = GitHubClient.new(app_id, test_private_key, installation_id)
        app_client.token.should eq "inst_token_old"
        app_client.list_rulesets("unurgunite/docscribe")
        app_client.token.should eq "inst_token_new"
      end

      it "handles token exchange error" do
        WebMock.stub(:post, "https://api.github.com/app/installations/789012/access_tokens")
          .to_return(status: 401, body: "Bad credentials")

        expect_raises(Exception, "HTTP 401") do
          GitHubClient.new(app_id, test_private_key, installation_id)
        end
      end

      it "uses installation token for API calls" do
        WebMock.stub(:post, "https://api.github.com/app/installations/789012/access_tokens")
          .to_return(body: %({"token": "inst_token", "expires_at": "2027-01-01T00:00:00Z"}))

        WebMock.stub(:get, "https://api.github.com/repos/unurgunite/docscribe/rulesets")
          .with(headers: {"Authorization" => "Bearer inst_token"})
          .to_return(body: "[]")

        app_client = GitHubClient.new(app_id, test_private_key, installation_id)
        result = app_client.list_rulesets("unurgunite/docscribe")
        result.should be_a(Array(Ruleset))
      end
    end
  end
end
