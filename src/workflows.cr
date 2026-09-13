require "digest/sha1"

module Gitorules
  # Raised when a workflow target violates the allowlist.
  #
  # Callers treat this as a hard error (exit code 2) raised before
  # any API write.
  class WorkflowError < Exception
  end

  # Planned sync action for a single workflow file.
  struct WorkflowPlan
    # Repository-relative target path (e.g. ".github/workflows/ci.yml").
    property target : String
    # Planned action: "create", "update", or "unchanged".
    property action : String
    # Local template content to write.
    property content : String
    # Blob sha of the existing remote file (nil for creates).
    property sha : String?

    def initialize(@target : String, @action : String, @content : String, @sha : String?)
    end
  end

  # Syncs GitHub Actions workflow files via the Contents API.
  #
  # Config maps a workflow key to a local template source:
  #
  # ```yaml
  # workflows:
  #   ci.yml:
  #     source: templates/ci.yml
  # ```
  #
  # Only `.github/workflows/*.yml` targets are allowed. Validation runs
  # before any API write; violations raise `WorkflowError`.
  class WorkflowResource
    TARGET_PREFIX = ".github/workflows/"

    @client : GitHubClient

    # @param client [GitHubClient] Authenticated GitHub API client
    def initialize(@client : GitHubClient)
    end

    # Resolves a config key to a repository-relative target path.
    #
    # Bare filenames ("ci.yml") resolve under `.github/workflows/`.
    # Keys that already carry the prefix are used as-is.
    #
    # @param key [String] Workflow config key
    # @return [String] Target path
    def self.target_path(key : String) : String
      key.starts_with?(TARGET_PREFIX) ? key : "#{TARGET_PREFIX}#{key}"
    end

    # Returns true when the target path is an allowed workflow file.
    #
    # Allowed: `.github/workflows/<name>.yml` (or `.yaml`), no
    # subdirectories, no path traversal.
    #
    # @param path [String] Repository-relative target path
    # @return [Bool] True when the path is allowed
    def self.valid_target?(path : String) : Bool
      return false unless path.starts_with?(TARGET_PREFIX)
      rest = path.lchop(TARGET_PREFIX)
      return false if rest.empty?
      return false if rest.includes?("/") || rest.includes?("\\") || rest.includes?("..")
      rest.ends_with?(".yml") || rest.ends_with?(".yaml")
    end

    # Computes the git blob sha for content.
    #
    # Matches the Contents API `sha` field, so equal shas mean equal
    # content and the sync can skip the write.
    #
    # @param content [String] Raw file content
    # @return [String] Hex blob sha
    def self.blob_sha(content : String) : String
      Digest::SHA1.hexdigest("blob #{content.bytesize}\0#{content}")
    end

    # Validates every workflow target before any API write.
    #
    # @param workflows [Hash(String, WorkflowConfig)] Configured workflows
    # @raise [WorkflowError] On the first disallowed target
    def validate!(workflows : Hash(String, WorkflowConfig)) : Nil
      workflows.each_key do |key|
        path = self.class.target_path(key)
        unless self.class.valid_target?(path)
          raise WorkflowError.new("Invalid workflow target '#{key}': only #{TARGET_PREFIX}*.yml paths are allowed")
        end
      end
    end

    # Validates workflows for all repos before any API write.
    #
    # @param config [Config] Parsed configuration
    # @param repos [Array(String)] Full repository names
    # @raise [WorkflowError] On the first disallowed target
    def validate_all!(config : Config, repos : Array(String)) : Nil
      repos.each do |repo|
        if workflows = config.workflows_for(repo)
          validate!(workflows)
        end
      end
    end

    # Plans workflow sync for a repo without writing.
    #
    # Compares the local template blob sha against the remote sha:
    # equal shas plan "unchanged", missing files plan "create",
    # differing files plan "update".
    #
    # @param repo [String] Full repository name (owner/name)
    # @param workflows [Hash(String, WorkflowConfig)] Configured workflows
    # @return [Array(WorkflowPlan)] Planned actions in config order
    # @raise [WorkflowError] On disallowed target
    # @raise [RuntimeError] When a template source is missing or unreadable
    def plan_repo(repo : String, workflows : Hash(String, WorkflowConfig)) : Array(WorkflowPlan)
      validate!(workflows)
      plans = [] of WorkflowPlan
      workflows.each do |key, entry|
        target = self.class.target_path(key)
        local = read_source(key, entry)
        local_sha = self.class.blob_sha(local)
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

    # Syncs workflows for a repo, writing via the Contents API.
    #
    # Dry-run mode performs zero PUTs and returns the plans that
    # would be applied.
    #
    # @param repo [String] Full repository name (owner/name)
    # @param workflows [Hash(String, WorkflowConfig)] Configured workflows
    # @param dry_run [Bool] Plan only, perform zero PUTs
    # @return [Array(WorkflowPlan)] Applied (or planned) actions
    def sync_repo(repo : String, workflows : Hash(String, WorkflowConfig), dry_run : Bool = false) : Array(WorkflowPlan)
      plans = plan_repo(repo, workflows)
      return plans if dry_run
      plans.each do |plan|
        next if plan.action == "unchanged"
        @client.put_contents(repo, plan.target, plan.content, plan.sha, "Sync #{plan.target} via gitorules")
      end
      plans
    end

    # Reads the local template source for a workflow entry.
    #
    # @param key [String] Workflow config key (for error messages)
    # @param entry [WorkflowConfig] Workflow configuration
    # @return [String] Template content
    # @raise [RuntimeError] When no source is configured or the file is unreadable
    private def read_source(key : String, entry : WorkflowConfig) : String
      source = entry.source
      if source.nil? || source.empty?
        raise "Workflow '#{key}' has no source configured"
      end
      begin
        File.read(source)
      rescue ex
        raise "Workflow source not found: #{source} (#{ex.message})"
      end
    end
  end
end
