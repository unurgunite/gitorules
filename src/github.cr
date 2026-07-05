require "http/client"
require "json"

module Gitorules
  # HTTP client for the GitHub REST API.
  #
  # Supports Rulesets and Repos endpoints. Authentication via
  # personal access token passed as Bearer token.
  class GitHubClient
    BASE_URL = "https://api.github.com"

    # Creates a client with the given GitHub token.
    def initialize(@token : String)
      @headers = HTTP::Headers{
        "Authorization" => "Bearer #{@token}",
        "Accept"        => "application/vnd.github+json",
        "User-Agent"    => "gitorules/0.1.0",
      }
    end

    # Lists rulesets for a repository (summary, without full rules).
    #
    # The list endpoint omits the `rules` field. Use `#get_ruleset`
    # to fetch a complete ruleset with rules.
    def list_rulesets(repo : String) : Array(Ruleset)
      resp = get("/repos/#{repo}/rulesets")
      Array(Ruleset).from_json(resp.body)
    end

    # Fetches a single ruleset with full rule details.
    def get_ruleset(repo : String, id : Int64) : Ruleset
      resp = get("/repos/#{repo}/rulesets/#{id}")
      Ruleset.from_json(resp.body)
    end

    # Creates a new ruleset. Returns the created ruleset with server-assigned ID.
    def create_ruleset(repo : String, ruleset : Ruleset) : Ruleset
      resp = post("/repos/#{repo}/rulesets", ruleset.to_json)
      Ruleset.from_json(resp.body)
    end

    # Replaces an existing ruleset. PUT is a full replacement, not a merge.
    def update_ruleset(repo : String, id : Int64, ruleset : Ruleset) : Ruleset
      resp = put("/repos/#{repo}/rulesets/#{id}", ruleset.to_json)
      Ruleset.from_json(resp.body)
    end

    # Lists repository names for an organization.
    def list_repos(org : String, type : String = "owner") : Array(String)
      resp = get("/orgs/#{org}/repos?per_page=100&type=#{type}")
      Array(JSON::Any).from_json(resp.body).map { |r| r["name"].to_s }
    end

    private def get(path : String) : HTTP::Client::Response
      HTTP::Client.get("#{BASE_URL}#{path}", headers: @headers) do |resp|
        handle_errors(resp)
        return resp
      end
    end

    private def post(path : String, body : String) : HTTP::Client::Response
      HTTP::Client.post("#{BASE_URL}#{path}", headers: @headers, body: body) do |resp|
        handle_errors(resp)
        return resp
      end
    end

    private def put(path : String, body : String) : HTTP::Client::Response
      HTTP::Client.put("#{BASE_URL}#{path}", headers: @headers, body: body) do |resp|
        handle_errors(resp)
        return resp
      end
    end

    private def handle_errors(resp : HTTP::Client::Response)
      case resp.status_code
      when 200..299
        return
      when 404
        raise "Not found"
      when 422
        raise "Validation error: #{resp.body}"
      else
        raise "HTTP #{resp.status_code}: #{resp.body}"
      end
    end
  end
end
