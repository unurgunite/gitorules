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
    #
    # @param token [String] GitHub personal access token
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
    #
    # @param repo [String] Full repository name (owner/name)
    # @return [Array(Ruleset)] List of rulesets without full rule details
    # @raise [RuntimeError] On API error (4xx, 5xx)
    def list_rulesets(repo : String) : Array(Ruleset)
      resp = get("/repos/#{repo}/rulesets")
      Array(Ruleset).from_json(resp.body)
    end

    # Fetches a single ruleset with full rule details.
    #
    # @param repo [String] Full repository name (owner/name)
    # @param id [Int64] Ruleset ID from GitHub
    # @return [Ruleset] Complete ruleset with all rules
    # @raise [RuntimeError] On API error (4xx, 5xx)
    def get_ruleset(repo : String, id : Int64) : Ruleset
      resp = get("/repos/#{repo}/rulesets/#{id}")
      Ruleset.from_json(resp.body)
    end

    # Creates a new ruleset. Returns the created ruleset with server-assigned ID.
    #
    # @param repo [String] Full repository name (owner/name)
    # @param ruleset [Ruleset] Ruleset configuration to create
    # @return [Ruleset] Created ruleset with server-assigned ID
    # @raise [RuntimeError] On API error (4xx, 5xx)
    def create_ruleset(repo : String, ruleset : Ruleset) : Ruleset
      resp = post("/repos/#{repo}/rulesets", ruleset.to_json)
      Ruleset.from_json(resp.body)
    end

    # Replaces an existing ruleset. PUT is a full replacement, not a merge.
    #
    # @param repo [String] Full repository name (owner/name)
    # @param id [Int64] Ruleset ID to update
    # @param ruleset [Ruleset] New ruleset configuration (replaces entirely)
    # @return [Ruleset] Updated ruleset from server
    # @raise [RuntimeError] On API error (4xx, 5xx)
    def update_ruleset(repo : String, id : Int64, ruleset : Ruleset) : Ruleset
      resp = put("/repos/#{repo}/rulesets/#{id}", ruleset.to_json)
      Ruleset.from_json(resp.body)
    end

    # Lists repository names for an organization.
    #
    # @param org [String] GitHub organization name
    # @param type [String] Repository type filter (default: "owner")
    # @return [Array(String)] List of repository names (without org prefix)
    # @raise [RuntimeError] On API error (4xx, 5xx)
    def list_repos(org : String, type : String = "owner") : Array(String)
      resp = get("/orgs/#{org}/repos?per_page=100&type=#{type}")
      Array(JSON::Any).from_json(resp.body).map(&.["name"].to_s)
    end

    # Performs an authenticated GET request.
    #
    # @param path [String] API path (e.g., "/repos/owner/name/rulesets")
    # @return [HTTP::Client::Response] Raw response
    # @raise [RuntimeError] On API error via handle_errors
    private def get(path : String) : HTTP::Client::Response
      HTTP::Client.get("#{BASE_URL}#{path}", headers: @headers) do |resp|
        handle_errors(resp)
        return resp
      end
    end

    # Performs an authenticated POST request with JSON body.
    #
    # @param path [String] API path (e.g., "/repos/owner/name/rulesets")
    # @param body [String] JSON request body
    # @return [HTTP::Client::Response] Raw response
    # @raise [RuntimeError] On API error via handle_errors
    private def post(path : String, body : String) : HTTP::Client::Response
      HTTP::Client.post("#{BASE_URL}#{path}", headers: @headers, body: body) do |resp|
        handle_errors(resp)
        return resp
      end
    end

    # Performs an authenticated PUT request with JSON body.
    #
    # @param path [String] API path (e.g., "/repos/owner/name/rulesets/1")
    # @param body [String] JSON request body (full replacement)
    # @return [HTTP::Client::Response] Raw response
    # @raise [RuntimeError] On API error via handle_errors
    private def put(path : String, body : String) : HTTP::Client::Response
      HTTP::Client.put("#{BASE_URL}#{path}", headers: @headers, body: body) do |resp|
        handle_errors(resp)
        return resp
      end
    end

    # Checks API response status and raises on errors.
    #
    # Success codes (200-299) pass through silently.
    # 404 raises "Not found", 422 raises with server error body,
    # all other codes raise with status code and body.
    #
    # @param resp [HTTP::Client::Response] Raw API response
    # @raise [RuntimeError] On 4xx or 5xx status code
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
