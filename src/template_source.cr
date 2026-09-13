require "base64"
require "digest/sha1"
require "digest/sha256"

module Gitorules
  # Parsed workflow template source.
  #
  # Local paths (e.g. `templates/ci.yml`) read from disk with unchanged
  # behavior. Remote references (`owner/repo@ref:path`) fetch a file
  # from another repository via the GitHub Contents API at the pinned
  # ref. A 40-hex ref is a commit SHA pin (fully reproducible); any
  # other ref is treated as a tag (or branch) name and the fetched blob
  # sha is reported for auditing.
  struct TemplateSource
    # Local file vs remote repository reference.
    enum Kind
      Local
      Remote
    end

    # Original source string from config.
    getter raw : String
    # Local or Remote.
    getter kind : Kind
    # Template repository (`owner/name`) for remote sources.
    getter repo : String?
    # Pinned tag or commit SHA for remote sources.
    getter ref : String?
    # File path inside the template repository.
    getter path : String?

    REPO_RE = /\A[A-Za-z0-9_.\-]+\/[A-Za-z0-9_.\-]+\z/
    SHA_RE  = /\A[0-9a-fA-F]{40}\z/

    def initialize(@raw : String, @kind : Kind, @repo : String? = nil, @ref : String? = nil, @path : String? = nil)
    end

    # Parses a raw source string.
    #
    # Anything without `@` before `:` is a local path and keeps the
    # previous behavior. Strings shaped like `owner/repo@ref:path`
    # become remote sources, otherwise a `WorkflowError` is raised.
    #
    # @param raw [String] Source string from config
    # @return [TemplateSource] Parsed source
    # @raise [WorkflowError] On blank or malformed remote references
    def self.parse(raw : String) : TemplateSource
      text = raw.strip
      if text.empty?
        raise WorkflowError.new("Invalid template source '#{raw}': source must not be blank")
      end

      at = text.index('@')
      return TemplateSource.new(raw, Kind::Local, path: text) unless at

      colon = text.index(':', at)
      return TemplateSource.new(raw, Kind::Local, path: text) unless colon

      repo_str = text[0...at]
      ref_str = text[at + 1...colon]
      path_str = text[colon + 1..]
      validate_remote!(raw, repo_str, ref_str, path_str)
    end

    # Validates remote parts and builds the source.
    private def self.validate_remote!(raw : String, repo_str : String, ref_str : String, path_str : String) : TemplateSource
      unless repo_str.matches?(REPO_RE)
        raise WorkflowError.new("Invalid template source '#{raw}': expected 'owner/repo@ref:path', got bad repo '#{repo_str}'")
      end
      if ref_str.empty? || ref_str.includes?(' ') || ref_str.includes?('\t') || ref_str.includes?('@') || ref_str.includes?(':')
        raise WorkflowError.new("Invalid template source '#{raw}': expected 'owner/repo@ref:path', got bad ref '#{ref_str}'")
      end
      if path_str.empty? || path_str.starts_with?('/')
        raise WorkflowError.new("Invalid template source '#{raw}': expected 'owner/repo@ref:path', got bad path '#{path_str}'")
      end
      TemplateSource.new(raw, Kind::Remote, repo: repo_str, ref: ref_str, path: path_str)
    end

    # True for remote repository references.
    def remote? : Bool
      kind.remote?
    end

    # True for local file paths.
    def local? : Bool
      kind.local?
    end

    # True when the pinned ref is a 40-hex commit SHA.
    def sha_pin? : Bool
      return false unless remote?
      return false unless value = ref
      !!(value =~ SHA_RE)
    end
  end

  # Fetched template content with its blob sha.
  #
  # For local sources the sha is the computed git blob sha. For remote
  # sources it is the `sha` field returned by the Contents API, which
  # makes applies reproducible and auditable.
  struct ResolvedTemplate
    # Raw file content.
    getter content : String
    # Blob sha of the content.
    getter blob_sha : String
    # Parsed source this content was resolved from.
    getter source : TemplateSource

    def initialize(@content : String, @blob_sha : String, @source : TemplateSource)
    end
  end

  # Resolves template sources with per-run memory and optional disk cache.
  #
  # Memory caching is always on and shared across instances so repeated
  # runs within one process (multiple repos, multiple workflows using
  # the same pin) perform a single HTTP fetch. Disk caching is opt-in
  # via *cache_dir* (or `GITORULES_CACHE_DIR`) for offline-friendly
  # repeated CLI runs.
  class TemplateResolver
    @@memory = {} of String => ResolvedTemplate
    @@lock = Mutex.new

    @client : GitHubClient
    @cache_dir : String?

    # @param client [GitHubClient] Authenticated API client
    # @param cache_dir [String?] Optional disk cache directory
    def initialize(@client : GitHubClient, cache_dir : String? = nil)
      env_dir = ENV["GITORULES_CACHE_DIR"]?
      picked = cache_dir || env_dir
      @cache_dir = picked.try(&.strip).try { |d| d.empty? ? nil : d }
    end

    # Clears the shared in-memory cache (used by specs).
    def self.clear_cache! : Nil
      @@lock.synchronize { @@memory.clear }
    end

    # Resolves a raw source string to content.
    #
    # @param raw [String] Source string from config
    # @return [ResolvedTemplate] Content with blob sha
    def resolve(raw : String) : ResolvedTemplate
      resolve_source(TemplateSource.parse(raw))
    end

    # Resolves an already parsed source.
    #
    # @param source [TemplateSource] Parsed source
    # @return [ResolvedTemplate] Content with blob sha
    def resolve_source(source : TemplateSource) : ResolvedTemplate
      return resolve_local(source) if source.local?
      resolve_remote(source)
    end

    # Reads a local template file from disk.
    private def resolve_local(source : TemplateSource) : ResolvedTemplate
      path = source.path || source.raw
      begin
        content = File.read(path)
      rescue ex
        raise "Workflow source not found: #{path} (#{ex.message})"
      end
      sha = Digest::SHA1.hexdigest("blob #{content.bytesize}\0#{content}")
      ResolvedTemplate.new(content, sha, source)
    end

    # Fetches a remote template via the Contents API with caching.
    private def resolve_remote(source : TemplateSource) : ResolvedTemplate
      key = source.raw
      if hit = memory_get(key)
        return hit
      end
      if hit = disk_get(key)
        memory_put(key, hit)
        return hit
      end

      repo = source.repo || ""
      template_path = source.path || ""
      ref = source.ref || ""
      fetched = @client.get_contents_at_ref(repo, template_path, ref)
      unless fetched
        raise "Workflow source not found: #{key} (template '#{template_path}' not found at ref '#{ref}' in '#{repo}')"
      end

      resolved = ResolvedTemplate.new(fetched[:content], fetched[:sha], source)
      memory_put(key, resolved)
      disk_put(key, resolved)
      resolved
    end

    private def memory_get(key : String) : ResolvedTemplate?
      @@lock.synchronize { @@memory[key]? }
    end

    private def memory_put(key : String, value : ResolvedTemplate) : Nil
      @@lock.synchronize { @@memory[key] = value }
    end

    private def disk_path(key : String) : String?
      dir = @cache_dir
      return unless dir
      File.join(dir, "#{Digest::SHA256.hexdigest(key)}.yml")
    end

    private def disk_get(key : String) : ResolvedTemplate?
      path = disk_path(key)
      return unless path
      return unless File.exists?(path)
      content = File.read(path)
      source = TemplateSource.parse(key)
      sha = Digest::SHA1.hexdigest("blob #{content.bytesize}\0#{content}")
      ResolvedTemplate.new(content, sha, source)
    rescue
      nil
    end

    private def disk_put(key : String, resolved : ResolvedTemplate) : Nil
      path = disk_path(key)
      return unless path
      dir = @cache_dir
      return unless dir
      begin
        Dir.mkdir_p(dir)
        File.write(path, resolved.content)
      rescue
      end
    end
  end
end
