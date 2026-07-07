require "json"
require "yaml"

# Supported merge methods for pull requests.
enum MergeMethod
  Merge
  Squash
  Rebase
end

# A single rule within a GitHub ruleset.
#
# Represents one enforcement rule such as `deletion`, `pull_request`,
# or `required_status_checks`. Parameters vary by rule type.
struct Rule
  include JSON::Serializable

  # Rule type identifier (e.g. "deletion", "pull_request", "required_status_checks").
  property type : String
  # Rule-specific parameters as a free-form JSON hash.
  property parameters : Hash(String, JSON::Any)?

  def initialize(@type : String, @parameters : Hash(String, JSON::Any)? = nil)
  end
end

# A complete GitHub ruleset with conditions and rules.
#
# Maps to the GitHub Rulesets API resource. When fetched from the
# list endpoint, `rules` may be empty — fetch by ID to get full rules.
struct Ruleset
  include JSON::Serializable

  # GitHub-assigned ruleset ID. Nil for new rulesets.
  property id : Int64?
  # Display name shown in GitHub UI.
  property name : String
  # Enforcement level: "active", "evaluate", or "disabled".
  property enforcement : String
  # Target type: "branch" (default) or "tag".
  property target : String
  # Conditions that determine which branches/tags this ruleset applies to.
  property conditions : Hash(String, JSON::Any)?
  # Ordered list of rules to enforce.
  property rules : Array(Rule)

  def initialize(
    @name : String,
    @enforcement : String = "active",
    @target : String = "branch",
    @conditions : Hash(String, JSON::Any)? = nil,
    @rules : Array(Rule) = [] of Rule,
  )
  end
end

# Configuration for a single branch type (e.g. default_branch, release).
#
# Deserialized from `.gitorules.yml`. Each field is optional — only
# specified rules are enforced.
struct BranchRuleConfig
  include YAML::Serializable

  def initialize
  end

  # Allow only merge commits. Value: "only".
  property merge : String?
  # Allow only squash merges. Value: "only".
  property squash : String?
  # Allow only rebase merges. Value: "only".
  property rebase : String?
  # Custom ruleset display name (overrides auto-generated).
  property name : String?
  # Branch name pattern for release branches (e.g. "v*").
  property pattern : String?
  # Required status check contexts (e.g. "check / check").
  property checks : Array(String)?
  # Require linear history (no merge commits).
  property linear_history : Bool?
  # Auto-delete head branches after merge.
  property delete_branch : Bool?

  # Resolves the effective merge method from config shorthand.
  #
  # Returns one of `"merge"`, `"squash"`, `"rebase"`, or `nil` if none set.
  @[YAML::Field(ignore: true)]
  def merge_method : String?
    return "squash" if squash == "only"
    return "rebase" if rebase == "only"
    return "merge" if merge == "only"
    nil
  end
end

# Per-org configuration within a multi-org config.
#
# Each org can have its own repository list and rules.
struct OrgConfig
  include YAML::Serializable

  def initialize
  end

  # Explicit list of repository names (short names, e.g. ["docscribe"]).
  property repos : Array(String)?
  # Map of branch type names to their rule configuration.
  property rules : Hash(String, BranchRuleConfig)?
end

# Top-level `.gitorules.yml` configuration.
struct Config
  include YAML::Serializable

  def initialize
  end

  # GitHub organization name (single-org mode).
  property org : String?
  # Explicit list of repository names (single-org mode).
  property repos : Array(String)?
  # Map of branch type names to their rule configuration (single-org mode).
  property rules : Hash(String, BranchRuleConfig)?
  # Multi-org configuration (overrides single-org fields).
  property orgs : Hash(String, OrgConfig)?

  # Returns rules for a specific repo, considering multi-org config.
  #
  # In single-org mode returns top-level rules.
  # In multi-org mode looks up which org owns the repo.
  #
  # @param repo [String] Full repository name (org/repo)
  # @return [Hash(String, BranchRuleConfig)?] Rules for the repo's org
  def rules_for(repo : String) : Hash(String, BranchRuleConfig)?
    return self.rules if self.rules # single-org mode

    org_name = repo.split("/").first?
    if org_name && (config_orgs = self.orgs)
      org_config = config_orgs[org_name]?
      return org_config.rules if org_config
    end

    nil
  end

  # Returns all known type keys across all orgs (for column headers).
  def all_type_keys : Array(String)
    org_keys = orgs.try &.values.flat_map { |o| o.rules.try(&.keys) || [] of String } || [] of String
    (org_keys + (rules.try(&.keys) || [] of String)).uniq
  end
end

# CLI options passed via command-line flags.
struct Options
  # Operation mode: "status", "apply", "init".
  property mode : String = "status"
  # Target specific repository (full name).
  property repo : String? = nil
  # Preview changes without applying.
  property? dry_run : Bool = false
  # Show diff without making changes.
  property? diff : Bool = false
  # JSON output mode (machine-readable).
  property? json : Bool = false
  # Suppress all output except errors.
  property? quiet : Bool = false
  # GitHub personal access token.
  property token : String? = nil
  # GitHub organization name.
  property org : String? = nil

  def initialize
  end
end
