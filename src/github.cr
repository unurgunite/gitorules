require "http/client"
require "json"
require "openssl"
require "base64"
require "uri"

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

    # Maximum retry attempts for rate-limit and server errors.
    MAX_RETRIES = 3
    # Base delay in seconds for exponential backoff (doubled per attempt).
    RETRY_BASE_DELAY = 0.1

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
      names = [] of String
      url : String? = "#{BASE_URL}/orgs/#{org}/repos?per_page=100&type=#{type}"
      while current = url
        resp = do_request(:get, current)
        handle_errors(resp)
        Array(JSON::Any).from_json(resp.body).each do |entry|
          names << entry["name"].to_s
        end
        url = next_page_url(resp.headers["Link"]?)
      end
      names
    end

    # Extracts the `rel="next"` URL from a GitHub Link header.
    #
    # @param link_header [String?] Raw Link header value or nil
    # @return [String?] Next page URL or nil when absent
    private def next_page_url(link_header : String?) : String?
      return unless link_header
      link_header.split(",").each do |part|
        if m = part.match(/<([^>]+)>\s*;\s*rel="([^"]+)"/)
          return m[1] if m[2] == "next"
        end
      end
      nil
    end

    # Returns true for statuses worth retrying with backoff.
    private def retryable_status?(code : Int32) : Bool
      code == 429 || (500..599).includes?(code)
    end

    # Computes backoff delay, honoring Retry-After when present.
    private def retry_delay(attempt : Int32, resp : HTTP::Client::Response?) : Time::Span
      if resp && (retry_after = resp.headers["Retry-After"]?)
        if secs = retry_after.to_f?
          return secs.clamp(0.0, 5.0).seconds
        end
      end
      (RETRY_BASE_DELAY * (2 ** attempt)).seconds
    end

    # Performs an HTTP request with retry on 429/5xx.
    #
    # @param method [Symbol] One of :get, :post, :put
    # @param url [String] Full URL to request
    # @param body [String?] Optional request body
    # @return [HTTP::Client::Response] Raw response (unvalidated)
    private def do_request(method : Symbol, url : String, body : String? = nil) : HTTP::Client::Response
      attempts = 0
      loop do
        ensure_token!
        resp = case method
               when :get
                 HTTP::Client.get(url, headers: @headers)
               when :post
                 HTTP::Client.post(url, headers: @headers, body: body)
               when :put
                 HTTP::Client.put(url, headers: @headers, body: body)
               else
                 raise "Unsupported HTTP method #{method}"
               end
        if retryable_status?(resp.status_code) && attempts < MAX_RETRIES
          sleep retry_delay(attempts, resp)
          attempts += 1
          next
        end
        return resp
      end
    end

    # Reads a repository file via the Contents API.
    #
    # Returns the blob sha and the decoded content, or nil when the
    # file does not exist (404). Other API errors raise.
    #
    # @param repo [String] Full repository name (owner/name)
    # @param path [String] Repository-relative path (e.g. ".github/workflows/ci.yml")
    # @return [NamedTuple(sha: String, content: String)?] Blob sha and decoded content
    # @raise [RuntimeError] On API error (non-404 4xx, 5xx)
    def get_contents(repo : String, path : String) : {sha: String, content: String}?
      ensure_token!
      resp = HTTP::Client.get("#{BASE_URL}/repos/#{repo}/contents/#{path}", headers: @headers)
      return if resp.status_code == 404
      handle_errors(resp)
      json = JSON.parse(resp.body)
      sha = json["sha"].to_s
      encoded = json["content"].to_s.gsub(/\s/, "")
      {sha: sha, content: String.new(Base64.decode(encoded))}
    end

    # Reads a template file from another repository at a pinned ref.
    #
    # Fetches `GET /repos/{repo}/contents/{path}?ref={ref}` so tag and
    # commit SHA pins resolve to exact file content. Returns nil on 404.
    #
    # @param repo [String] Template repository (owner/name)
    # @param path [String] File path inside the template repository
    # @param ref [String] Tag name or commit SHA pin
    # @return [NamedTuple(sha: String, content: String)?] Blob sha and decoded content
    # @raise [RuntimeError] On API error (non-404 4xx, 5xx)
    def get_contents_at_ref(repo : String, path : String, ref : String) : {sha: String, content: String}?
      ensure_token!
      encoded_ref = URI.encode_path(ref)
      resp = HTTP::Client.get("#{BASE_URL}/repos/#{repo}/contents/#{path}?ref=#{encoded_ref}", headers: @headers)
      return if resp.status_code == 404
      handle_errors(resp)
      json = JSON.parse(resp.body)
      unless json.as_h?
        raise "Template '#{path}' in '#{repo}@#{ref}' is not a file"
      end
      sha = json["sha"].to_s
      encoded = json["content"].to_s.gsub(/\s/, "")
      {sha: sha, content: String.new(Base64.decode(encoded))}
    end

    # Creates or updates a repository file via the Contents API.
    #
    # Pass sha for updates, nil for creates. Content is base64-encoded
    # before sending.
    #
    # @param repo [String] Full repository name (owner/name)
    # @param path [String] Repository-relative path (e.g. ".github/workflows/ci.yml")
    # @param content [String] Raw file content
    # @param sha [String?] Blob sha of the existing file (nil to create)
    # @param message [String] Commit message
    # @return [String] Response body
    # @raise [RuntimeError] On API error (4xx, 5xx)
    def put_contents(repo : String, path : String, content : String, sha : String?, message : String) : String
      payload = JSON.build do |json|
        json.object do
          json.field "message", message
          json.field "content", Base64.strict_encode(content)
          json.field "sha", sha if sha
        end
      end
      put("/repos/#{repo}/contents/#{path}", payload)
    end

    # Performs an authenticated GET request.
    #
    # @param path [String] API path (e.g., "/repos/owner/name/rulesets")
    # @return [String] Response body
    # @raise [RuntimeError] On API error via handle_errors
    private def get(path : String) : String
      url = path.starts_with?("http") ? path : "#{BASE_URL}#{path}"
      resp = do_request(:get, url)
      handle_errors(resp)
      resp.body
    end

    private def post(path : String, body : String) : String
      url = path.starts_with?("http") ? path : "#{BASE_URL}#{path}"
      resp = do_request(:post, url, body)
      handle_errors(resp)
      resp.body
    end

    private def put(path : String, body : String) : String
      url = path.starts_with?("http") ? path : "#{BASE_URL}#{path}"
      resp = do_request(:put, url, body)
      handle_errors(resp)
      resp.body
    end

    # Truncates 422 error body to 200 characters.
    #
    # Long bodies (>200 chars) get truncated with "(truncated)" suffix.
    # Other status codes return full body with HTTP prefix.
    #
    # @param resp [HTTP::Client::Response] Raw API response
    # @return [String] Formatted error message
    private def format_error(resp : HTTP::Client::Response) : String
      if resp.status_code == 422 && resp.body.size > 200
        "HTTP 422: #{resp.body[0, 200]}... (truncated)"
      elsif resp.status_code == 422
        "HTTP 422: #{resp.body}"
      else
        "HTTP #{resp.status_code}: #{resp.body}"
      end
    end

    # Checks API response status and raises on errors.
    #
    # Success codes (200-299) pass through silently.
    # 404 raises "Not found", all other codes raise with formatted error.
    #
    # @param resp [HTTP::Client::Response] Raw API response
    # @raise [RuntimeError] On 4xx or 5xx status code
    private def handle_errors(resp : HTTP::Client::Response)
      case resp.status_code
      when 200..299
        return
      when 404
        raise "Not found"
      else
        raise format_error(resp)
      end
    end

    # Lists issue labels for a repository.
    #
    # @param repo [String] Full repository name (owner/name)
    # @return [Array(Label)] All labels (up to 100)
    # @raise [RuntimeError] On API error (4xx, 5xx)
    def list_labels(repo : String) : Array(Label)
      body = get("/repos/#{repo}/labels?per_page=100")
      Array(Label).from_json(body)
    end

    # Creates a new issue label.
    #
    # @param repo [String] Full repository name (owner/name)
    # @param label [Label] Label with name, color, and description
    # @return [Label] Created label
    # @raise [RuntimeError] On API error (4xx, 5xx)
    def create_label(repo : String, label : Label) : Label
      payload = {"name" => label.name, "color" => label.norm_color, "description" => label.description}
      body = post("/repos/#{repo}/labels", payload.to_json)
      Label.from_json(body)
    end

    # Updates an existing issue label.
    #
    # @param repo [String] Full repository name (owner/name)
    # @param current_name [String] Current label name in the URL
    # @param label [Label] New label attributes
    # @return [Label] Updated label
    # @raise [RuntimeError] On API error (4xx, 5xx)
    def update_label(repo : String, current_name : String, label : Label) : Label
      payload = {"new_name" => label.name, "color" => label.norm_color, "description" => label.description}
      body = patch("/repos/#{repo}/labels/#{URI.encode_path_segment(current_name)}", payload.to_json)
      Label.from_json(body)
    end

    # Deletes an issue label.
    #
    # @param repo [String] Full repository name (owner/name)
    # @param name [String] Label name
    # @raise [RuntimeError] On API error (4xx, 5xx)
    def delete_label(repo : String, name : String) : Nil
      delete("/repos/#{repo}/labels/#{URI.encode_path_segment(name)}")
      nil
    end

    # Performs an authenticated PATCH request.
    #
    # @param path [String] API path
    # @param body [String] JSON request body
    # @return [String] Response body
    # @raise [RuntimeError] On API error via handle_errors
    private def patch(path : String, body : String) : String
      ensure_token!
      resp = HTTP::Client.patch("#{BASE_URL}#{path}", headers: @headers, body: body)
      handle_errors(resp)
      resp.body
    end

    # Performs an authenticated DELETE request.
    #
    # @param path [String] API path
    # @return [String] Response body
    # @raise [RuntimeError] On API error via handle_errors
    private def delete(path : String) : String
      ensure_token!
      resp = HTTP::Client.delete("#{BASE_URL}#{path}", headers: @headers)
      handle_errors(resp)
      resp.body
    end
  end
end
