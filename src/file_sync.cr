module Gitorules
  # Raised when a file target violates the allowlist.
  #
  # Subclasses WorkflowError so existing CLI rescue paths map it
  # to exit code 2 without additional wiring.
  class FileSyncError < WorkflowError
  end

  # Allowlist for generic file sync.
  #
  # Maps a file class to its allowed repository-relative paths.
  # Anything outside this mapping is rejected before any API write.
  module FileSync
    # Linter configs synced to the repository root.
    LINTER_FILES = [".rubocop.yml", ".ameba.yml"]
    # Runtime version pins synced to the repository root.
    VERSION_FILES = [".ruby-version", ".nvmrc"]
    # Dependabot config for the repository.
    DEPENDABOT_FILES = [".github/dependabot.yml"]
    # Issue template directory prefix.
    ISSUE_TEMPLATE_PREFIX = ".github/ISSUE_TEMPLATE/"

    # Explicit class-to-paths mapping. The union of all values
    # defines the allowlist; `class_for` resolves the reverse lookup.
    CLASS_PATHS = {
      "linter"         => LINTER_FILES,
      "version"        => VERSION_FILES,
      "dependabot"     => DEPENDABOT_FILES,
      "issue_template" => ["#{ISSUE_TEMPLATE_PREFIX}*.md"],
      "workflow"       => [".github/workflows/*.yml", ".github/workflows/*.yaml"],
    }

    # Returns true when the target path may be synced.
    #
    # Allowed: exact linter, version and dependabot paths, workflow
    # files via WorkflowResource, and `*.md` files directly under
    # `.github/ISSUE_TEMPLATE/`.
    #
    # @param path [String] Repository-relative target path
    # @return [Bool] True when the path is allowlisted
    def self.allowed?(path : String) : Bool
      return true if LINTER_FILES.includes?(path)
      return true if VERSION_FILES.includes?(path)
      return true if DEPENDABOT_FILES.includes?(path)
      return true if WorkflowResource.valid_target?(path)
      issue_template_target?(path)
    end

    # Returns true for `*.md` files directly under the template dir.
    #
    # Subdirectories, traversal segments and non-markdown
    # extensions are rejected.
    #
    # @param path [String] Repository-relative target path
    # @return [Bool] True for valid issue template paths
    def self.issue_template_target?(path : String) : Bool
      return false unless path.starts_with?(ISSUE_TEMPLATE_PREFIX)
      rest = path.lchop(ISSUE_TEMPLATE_PREFIX)
      return false if rest.empty?
      return false if rest.includes?("/") || rest.includes?("\\") || rest.includes?("..")
      rest.ends_with?(".md")
    end

    # Resolves the file class for an allowlisted path.
    #
    # @param path [String] Repository-relative target path
    # @return [String?] Class name or nil when not allowlisted
    def self.class_for(path : String) : String?
      return "linter" if LINTER_FILES.includes?(path)
      return "version" if VERSION_FILES.includes?(path)
      return "dependabot" if DEPENDABOT_FILES.includes?(path)
      return "workflow" if WorkflowResource.valid_target?(path)
      return "issue_template" if issue_template_target?(path)
      nil
    end

    # Validates every file target before any API write.
    #
    # Keys are repository-relative target paths used as-is.
    #
    # @param files [Hash(String, WorkflowConfig)] Configured files
    # @raise [FileSyncError] On the first disallowed target
    def self.validate!(files : Hash(String, WorkflowConfig)) : Nil
      files.each_key do |key|
        unless allowed?(key)
          raise FileSyncError.new("Invalid file target '#{key}': only allowlisted paths may be synced (#{CLASS_PATHS.keys.join(", ")})")
        end
      end
    end

    # Validates files for all repos before any API write.
    #
    # @param config [Config] Parsed configuration
    # @param repos [Array(String)] Full repository names
    # @raise [FileSyncError] On the first disallowed target
    def self.validate_all!(config : Config, repos : Array(String)) : Nil
      repos.each do |repo|
        if files = config.files_for(repo)
          validate!(files)
        end
      end
    end
  end

  # Syncs generic allowlisted files via the Contents API.
  #
  # Reuses the Contents-API mechanics from WorkflowResource (GET with
  # sha, PUT update, sha-match skip, dry-run zero writes) without
  # duplicating client or hashing logic.
  class FileResource
    @client : GitHubClient

    # @param client [GitHubClient] Authenticated GitHub API client
    def initialize(@client : GitHubClient)
    end

    # Validates every file target before any API write.
    #
    # @param files [Hash(String, WorkflowConfig)] Configured files
    # @raise [FileSyncError] On the first disallowed target
    def validate!(files : Hash(String, WorkflowConfig)) : Nil
      FileSync.validate!(files)
    end

    # Validates files for all repos before any API write.
    #
    # @param config [Config] Parsed configuration
    # @param repos [Array(String)] Full repository names
    # @raise [FileSyncError] On the first disallowed target
    def validate_all!(config : Config, repos : Array(String)) : Nil
      FileSync.validate_all!(config, repos)
    end

    # Plans file sync for a repo without writing.
    #
    # Compares the local source blob sha against the remote sha:
    # equal shas plan "unchanged", missing files plan "create",
    # differing files plan "update".
    #
    # @param repo [String] Full repository name (owner/name)
    # @param files [Hash(String, WorkflowConfig)] Configured files
    # @return [Array(WorkflowPlan)] Planned actions in config order
    # @raise [FileSyncError] On disallowed target
    # @raise [RuntimeError] When a source is missing or unreadable
    def plan_repo(repo : String, files : Hash(String, WorkflowConfig)) : Array(WorkflowPlan)
      validate!(files)
      plans = [] of WorkflowPlan
      files.each do |target, entry|
        local = read_source(target, entry)
        local_sha = WorkflowResource.blob_sha(local)
        remote = @client.get_contents(repo, target)
        if remote && remote[:sha] == local_sha
          plans << WorkflowPlan.new(target, "unchanged", local, remote[:sha])
        elsif remote
          plans << WorkflowPlan.new(target, "update", local, remote[:sha])
        else
          plans << WorkflowPlan.new(target, "create", local, nil)
        end
      end
      plans
    end

    # Syncs files for a repo, writing via the Contents API.
    #
    # Dry-run mode performs zero PUTs and returns the plans that
    # would be applied.
    #
    # @param repo [String] Full repository name (owner/name)
    # @param files [Hash(String, WorkflowConfig)] Configured files
    # @param dry_run [Bool] Plan only, perform zero PUTs
    # @return [Array(WorkflowPlan)] Applied (or planned) actions
    def sync_repo(repo : String, files : Hash(String, WorkflowConfig), dry_run : Bool = false) : Array(WorkflowPlan)
      plans = plan_repo(repo, files)
      return plans if dry_run
      plans.each do |plan|
        next if plan.action == "unchanged"
        @client.put_contents(repo, plan.target, plan.content, plan.sha, "Sync #{plan.target} via gitorules")
      end
      plans
    end

    # Reads the local source for a file entry.
    #
    # @param key [String] File target (for error messages)
    # @param entry [WorkflowConfig] File configuration
    # @return [String] Source content
    # @raise [RuntimeError] When no source is configured or the file is unreadable
    private def read_source(key : String, entry : WorkflowConfig) : String
      source = entry.source
      if source.nil? || source.empty?
        raise "File '#{key}' has no source configured"
      end
      begin
        File.read(source)
      rescue ex
        raise "File source not found: #{source} (#{ex.message})"
      end
    end
  end
end
