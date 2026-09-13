require "digest/sha1"
require "yaml"

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
    # Template content to write (local file or remote pin).
    property content : String
    # Blob sha of the existing remote file (nil for creates).
    property sha : String?
    # Original source string from config.
    property source : String
    # Resolved template blob sha (auditable pin resolution).
    property resolved_sha : String?
    # Pinned ref for remote sources (nil for local files).
    property remote_ref : String?

    def initialize(@target : String, @action : String, @content : String, @sha : String?, @source : String = "", @resolved_sha : String? = nil, @remote_ref : String? = nil)
    end

    # True when the template came from a remote `repo@ref:path` pin.
    def remote? : Bool
      !remote_ref.nil?
    end
  end

  # Syncs GitHub Actions workflow files via the Contents API.
  #
  # Config maps a workflow key to a template source, either local:
  #
  # ```yaml
  # workflows:
  #   ci.yml:
  #     source: templates/ci.yml
  # ```
  #
  # Per-repo extension points use an explicit extra-steps file,
  # or a remote pin:
  #
  # ```yaml
  # workflows:
  #   ci.yml:
  #     source: templates/gradle/ci.yml
  #     extra_steps: templates/gradle/extra-steps.example.yml
  # ```
  #
  # ```yaml
  # workflows:
  #   ci.yml:
  #     source: FlorexLabs/templates@v1:ruby/ci.yml
  # ```
  #
  # Extra steps are appended verbatim after the anchor marker
  # (`# gitorules:extra-steps`) in the base template. The base file
  # stays intact; there are no silent full-file overrides. Unknown
  # anchors raise `WorkflowError`.
  #
  # Only `.github/workflows/*.yml` targets are allowed. Validation runs
  # before any API write; violations raise `WorkflowError`.
  class WorkflowResource
    TARGET_PREFIX              = ".github/workflows/"
    EXTRA_STEPS_ANCHOR_DEFAULT = "gitorules:extra-steps"

    @client : GitHubClient
    @resolver : TemplateResolver

    # @param client [GitHubClient] Authenticated GitHub API client
    def initialize(@client : GitHubClient, cache_dir : String? = nil)
      @resolver = TemplateResolver.new(@client, cache_dir)
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

    # Resolves the anchor marker name for a workflow entry.
    #
    # @param entry [WorkflowConfig] Workflow configuration
    # @return [String] Anchor name without the leading `#`
    def self.extra_anchor(entry : WorkflowConfig) : String
      raw = entry.extra_steps_anchor.try(&.strip)
      if raw.nil? || raw.empty?
        EXTRA_STEPS_ANCHOR_DEFAULT
      else
        raw
      end
    end

    # Returns true when a base template line is the anchor marker.
    #
    # @param line [String] Single base template line
    # @param anchor [String] Anchor name (e.g. "gitorules:extra-steps")
    # @return [Bool] True for the `# <anchor>` comment line
    def self.anchor_line?(line : String, anchor : String) : Bool
      line.strip == "# #{anchor.strip}"
    end

    # Inserts extra steps after the anchor marker.
    #
    # The base content is otherwise untouched. Blank extra content
    # returns the base unchanged.
    #
    # @param base [String] Base template content
    # @param extra [String] Extra steps YAML snippet (list of steps)
    # @param anchor [String] Anchor marker name
    # @return [String] Resolved content with extra steps inserted
    # @raise [WorkflowError] On blank anchor, invalid YAML, or unknown anchor
    def self.apply_extra_steps(base : String, extra : String, anchor : String = EXTRA_STEPS_ANCHOR_DEFAULT) : String
      clean_anchor = anchor.strip
      if clean_anchor.empty?
        raise WorkflowError.new("Invalid extra_steps_anchor: anchor must not be blank")
      end
      return base if extra.strip.empty?

      begin
        parsed = YAML.parse(extra)
      rescue ex : YAML::ParseException
        raise WorkflowError.new("Invalid extra_steps YAML (#{ex.message}). Fix: provide a YAML list of steps starting with '- name: ...'.")
      end
      unless parsed.as_a?
        raise WorkflowError.new("Invalid extra_steps content: expected a YAML list of steps. Fix: start the file with '- name: ...'.")
      end

      base_lines = base.split("\n")
      had_trailing_newline = base.ends_with?("\n")
      # Drop the artifact empty element from a trailing newline for indexing.
      base_lines.pop if had_trailing_newline && !base_lines.empty? && base_lines.last.empty?

      idx = base_lines.index { |line| anchor_line?(line, clean_anchor) }
      unless idx
        raise WorkflowError.new("Unknown extra_steps anchor '#{clean_anchor}': anchor marker not found in base template")
      end

      extra_lines = extra.rstrip("\n").split("\n")
      resolved = [] of String
      resolved.concat(base_lines[0..idx])
      resolved.concat(extra_lines)
      if idx + 1 < base_lines.size
        resolved.concat(base_lines[(idx + 1)..])
      end
      result = resolved.join("\n")
      result += "\n" if had_trailing_newline || !result.ends_with?("\n")
      result
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
    # Compares the template blob sha against the remote sha:
    # equal shas plan "unchanged", missing files plan "create",
    # differing files plan "update". Resolved content includes any
    # configured `extra_steps` appended at the anchor marker.
    # Local paths read from disk; `repo@ref:path` pins fetch via the
    # Contents API with per-run caching, so repeated resolves perform
    # zero extra HTTP calls.
    #
    # @param repo [String] Full repository name (owner/name)
    # @param workflows [Hash(String, WorkflowConfig)] Configured workflows
    # @return [Array(WorkflowPlan)] Planned actions in config order
    # @raise [WorkflowError] On disallowed target or unknown anchor
    # @raise [RuntimeError] When a template source is missing or unreadable
    def plan_repo(repo : String, workflows : Hash(String, WorkflowConfig)) : Array(WorkflowPlan)
      validate!(workflows)
      plans = [] of WorkflowPlan
      workflows.each do |key, entry|
        target = self.class.target_path(key)
        resolved = resolve_entry(key, entry)
        local = apply_configured_extra_steps(resolved.content, entry)
        local_sha = self.class.blob_sha(local)
        remote = @client.get_contents(repo, target)
        if remote && remote[:sha] == local_sha
          plans << WorkflowPlan.new(target, "unchanged", local, remote[:sha], entry.source || "", local_sha, resolved.source.remote? ? resolved.source.ref : nil)
        elsif remote
          plans << WorkflowPlan.new(target, "update", local, remote[:sha], entry.source || "", local_sha, resolved.source.remote? ? resolved.source.ref : nil)
        else
          plans << WorkflowPlan.new(target, "create", local, nil, entry.source || "", local_sha, resolved.source.remote? ? resolved.source.ref : nil)
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

    # Resolves the template source for a workflow entry.
    #
    # Local paths read from disk with unchanged behavior. Remote
    # `repo@ref:path` pins fetch via the Contents API with caching.
    #
    # @param key [String] Workflow config key (for error messages)
    # @param entry [WorkflowConfig] Workflow configuration
    # @return [ResolvedTemplate] Content with blob sha
    # @raise [RuntimeError] When no source is configured
    # @raise [WorkflowError] On malformed remote references
    private def resolve_entry(key : String, entry : WorkflowConfig) : ResolvedTemplate
      source = entry.source
      if source.nil? || source.empty?
        raise "Workflow '#{key}' has no source configured"
      end
      @resolver.resolve(source)
    end

    # Reads the local template source for a workflow entry.
    #
    # Kept for compatibility; delegates to the resolver so local
    # behavior stays identical while remote pins resolve via API.
    #
    # @param key [String] Workflow config key (for error messages)
    # @param entry [WorkflowConfig] Workflow configuration
    # @return [String] Template content
    # @raise [RuntimeError] When no source is configured or the file is unreadable
    private def read_source(key : String, entry : WorkflowConfig) : String
      resolve_entry(key, entry).content
    end

    # Reads resolved template content with extra steps applied.
    #
    # Base content stays intact; configured `extra_steps` are appended
    # after the anchor marker. Entries without `extra_steps` return
    # the base content unchanged.
    #
    # @param key [String] Workflow config key (for error messages)
    # @param entry [WorkflowConfig] Workflow configuration
    # @return [String] Resolved content to sync
    # @raise [WorkflowError] On unknown anchor or invalid extra steps
    # @raise [RuntimeError] When a source file is missing or unreadable
    def read_resolved(key : String, entry : WorkflowConfig) : String
      resolved = resolve_entry(key, entry)
      apply_configured_extra_steps(resolved.content, entry)
    end

    # Appends configured `extra_steps` to base template content.
    #
    # @param base [String] Resolved base template content
    # @param entry [WorkflowConfig] Workflow configuration
    # @return [String] Content with extra steps, or base unchanged
    # @raise [WorkflowError] On unknown anchor or invalid extra steps
    # @raise [RuntimeError] When the extra steps file is unreadable
    private def apply_configured_extra_steps(base : String, entry : WorkflowConfig) : String
      extra_path = entry.extra_steps.try(&.strip)
      return base if extra_path.nil? || extra_path.empty?

      begin
        extra = File.read(extra_path)
      rescue ex
        raise "Workflow extra_steps not found: #{extra_path} (#{ex.message})"
      end
      self.class.apply_extra_steps(base, extra, self.class.extra_anchor(entry))
    end
  end
end
