require "http/client"
require "json"
require "openssl"
require "base64"

# Extends Crystal's LibCrypto with RSA/PEM functions needed for JWT signing.
# Crystal's LibCrypto already has correct @[Link(...)] per platform.
lib LibCrypto
  NID_SHA256 = 672

  fun bio_new_mem_buf = BIO_new_mem_buf(data : Void*, len : Int32) : Void*
  fun pem_read_bio_privatekey = PEM_read_bio_PrivateKey(bp : Void*, x : Void*, cb : Void*, u : Void*) : Void*
  fun evp_pkey_free = EVP_PKEY_free(pkey : Void*) : Void*
  fun evp_pkey_get1_rsa = EVP_PKEY_get1_RSA(pkey : Void*) : Void*
  fun rsa_free = RSA_free(rsa : Void*) : Void*
  fun rsa_size = RSA_size(rsa : Void*) : Int32
  fun rsa_sign = RSA_sign(type : Int32, m : UInt8*, m_len : UInt32, sigret : UInt8*, siglen : UInt32*, rsa : Void*) : Int32
end

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

    # Frees a BIO allocated by bio_new_mem_buf.
    private def free_bio(bio : Void*)
      LibCrypto.BIO_free(bio.as(LibCrypto::Bio*))
    end

    # Generates a RS256 JWT for GitHub App authentication.
    #
    # Signs JWT with RSA private key via in-process libcrypto FFI.
    # No temp files, no CLI process — key never leaves memory.
    #
    # @return [String] Signed JWT string
    # @raise [RuntimeError] If private key is nil or RSA signing fails
    private def generate_jwt : String
      key = @private_key
      raise "JWT signing failed: private key is nil" unless key

      header = Base64.urlsafe_encode(%({"alg":"RS256","typ":"JWT"}), padding: false)
      now = Time.utc.to_unix
      payload = Base64.urlsafe_encode(%({"iat":#{now},"exp":#{now + 600},"iss":"#{@app_id}"}), padding: false)
      data = "#{header}.#{payload}"

      digest = OpenSSL::Digest.new("SHA256")
      digest.update(data)
      hash = digest.final

      bio = LibCrypto.bio_new_mem_buf(key.to_unsafe, key.bytesize)
      raise "JWT signing failed: BIO allocation error" if bio.null?

      pkey = LibCrypto.pem_read_bio_privatekey(bio, nil, nil, nil)
      free_bio(bio)
      raise "JWT signing failed: unable to parse private key" if pkey.null?

      rsa = LibCrypto.evp_pkey_get1_rsa(pkey)
      LibCrypto.evp_pkey_free(pkey)
      raise "JWT signing failed: not an RSA key" if rsa.null?

      sig = Bytes.new(LibCrypto.rsa_size(rsa))
      sig_len = UInt32.new(0)
      ret = LibCrypto.rsa_sign(LibCrypto::NID_SHA256, hash, hash.size, sig, pointerof(sig_len), rsa)
      LibCrypto.rsa_free(rsa)

      unless ret == 1 && sig_len > 0
        raise "JWT signing failed: RSA_sign returned #{ret}"
      end

      signature = Base64.urlsafe_encode(sig[0, sig_len], padding: false)
      "#{data}.#{signature}"
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
      body = get("/repos/#{repo}/rulesets")
      Array(Ruleset).from_json(body)
    end

    def get_ruleset(repo : String, id : Int64) : Ruleset
      body = get("/repos/#{repo}/rulesets/#{id}")
      Ruleset.from_json(body)
    end

    def create_ruleset(repo : String, ruleset : Ruleset) : Ruleset
      body = post("/repos/#{repo}/rulesets", ruleset.to_json)
      Ruleset.from_json(body)
    end

    def update_ruleset(repo : String, id : Int64, ruleset : Ruleset) : Ruleset
      body = put("/repos/#{repo}/rulesets/#{id}", ruleset.to_json)
      Ruleset.from_json(body)
    end

    def list_repos(org : String, type : String = "owner") : Array(String)
      body = get("/orgs/#{org}/repos?per_page=100&type=#{type}")
      Array(JSON::Any).from_json(body).map(&.["name"].to_s)
    end

    # Performs an authenticated GET request.
    #
    # @param path [String] API path (e.g., "/repos/owner/name/rulesets")
    # @return [String] Response body
    # @raise [RuntimeError] On API error via handle_errors
    private def get(path : String) : String
      ensure_token!
      resp = HTTP::Client.get("#{BASE_URL}#{path}", headers: @headers)
      handle_errors(resp)
      resp.body
    end

    private def post(path : String, body : String) : String
      ensure_token!
      resp = HTTP::Client.post("#{BASE_URL}#{path}", headers: @headers, body: body)
      handle_errors(resp)
      resp.body
    end

    private def put(path : String, body : String) : String
      ensure_token!
      resp = HTTP::Client.put("#{BASE_URL}#{path}", headers: @headers, body: body)
      handle_errors(resp)
      resp.body
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
