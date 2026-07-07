require "http/client"
require "json"
require "openssl"
require "base64"

module Gitorules
  # HTTP client for the GitHub REST API.
  #
  # Supports Rulesets and Repos endpoints. Authentication via
  # personal access token or GitHub App (JWT → installation token).
  class GitHubClient
    BASE_URL = "https://api.github.com"

    # Cached installation token with expiry time.
    private record AppInstallationToken, token : String, expires_at : Time do
      def expired? : Bool
        Time.utc >= expires_at
      end
    end

    @token : String?
    @app_id : String?
    @private_key : String?
    @installation_id : String?
    @cached_token : AppInstallationToken?
    @headers : HTTP::Headers

    # Returns the effective auth token (PAT or installation token).
    getter token : String?

    # Creates a client with PAT auth.
    #
    # @param token [String] GitHub personal access token
    def initialize(@token : String)
      @headers = HTTP::Headers{
        "Authorization" => "Bearer #{@token}",
        "Accept"        => "application/vnd.github+json",
        "User-Agent"    => "gitorules/0.1.0",
      }
    end

    # Creates a client with GitHub App auth.
    #
    # Generates a JWT from the app credentials, exchanges it for an
    # installation token, and auto-refreshes the token when expired.
    #
    # @param app_id [String] GitHub App ID
    # @param private_key [String] RSA private key in PEM format
    # @param installation_id [String] GitHub App installation ID
    def initialize(@app_id : String, @private_key : String, @installation_id : String)
      @token = nil
      token = fetch_installation_token
      @cached_token = token
      @token = token.token
      @headers = HTTP::Headers{
        "Authorization" => "Bearer #{token.token}",
        "Accept"        => "application/vnd.github+json",
        "User-Agent"    => "gitorules/0.1.0",
      }
    end

    # Ensures the installation token is still valid.
    #
    # For PAT mode this is a no-op. For GitHub App mode, refreshes
    # the token via JWT exchange if the current one is expired.
    private def ensure_token!
      token = @cached_token
      return unless token
      return unless token.expired?
      fresh = fetch_installation_token
      @cached_token = fresh
      @token = fresh.token
      @headers["Authorization"] = "Bearer #{fresh.token}"
    end

    # Fetches a fresh installation token from GitHub.
    #
    # Generates a short-lived JWT and exchanges it for an installation
    # access token (valid 1 hour).
    #
    # @return [AppInstallationToken] New token with expiry
    private def fetch_installation_token : AppInstallationToken
      jwt = generate_jwt
      resp = HTTP::Client.post(
        "#{BASE_URL}/app/installations/#{@installation_id}/access_tokens",
        headers: HTTP::Headers{
          "Authorization" => "Bearer #{jwt}",
          "Accept"        => "application/vnd.github+json",
        },
        body: "{}"
      )
      handle_errors(resp)
      json = JSON.parse(resp.body)
      token = json["token"].to_s
      expires_at = Time.parse_iso8601(json["expires_at"].to_s)
      AppInstallationToken.new(token, expires_at)
    end

    # Generates a RS256 JWT for GitHub App authentication.
    #
    # The JWT is signed with the app's RSA private key and contains
    # the app ID (iss), issued-at (iat), and expiration (exp = now + 10 min).
    # Uses system `openssl` CLI for signing (no external Crystal shards).
    #
    # @return [String] Signed JWT string
    private def generate_jwt : String
      header = Base64.urlsafe_encode(%({"alg":"RS256","typ":"JWT"}), padding: false)
      now = Time.utc.to_unix
      payload = Base64.urlsafe_encode(%({"iat":#{now},"exp":#{now + 600},"iss":"#{@app_id}"}), padding: false)
      data = "#{header}.#{payload}"

      sig_input = IO::Memory.new(data)
      sig_output = IO::Memory.new
      key_path = File.tempname("gitorules-key")
      File.write(key_path, @private_key)

      Process.run("openssl", ["dgst", "-sha256", "-sign", key_path],
        input: sig_input, output: sig_output, error: STDERR)
      File.delete(key_path)

      sig = Base64.urlsafe_encode(sig_output.to_s, padding: false)
      "#{data}.#{sig}"
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
      ensure_token!
      HTTP::Client.get("#{BASE_URL}#{path}", headers: @headers) do |resp|
        handle_errors(resp)
        return resp
      end
    end

    private def post(path : String, body : String) : HTTP::Client::Response
      ensure_token!
      HTTP::Client.post("#{BASE_URL}#{path}", headers: @headers, body: body) do |resp|
        handle_errors(resp)
        return resp
      end
    end

    private def put(path : String, body : String) : HTTP::Client::Response
      ensure_token!
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
