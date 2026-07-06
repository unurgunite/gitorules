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

# Top-level `.gitorules.yml` configuration.
struct Config
  include YAML::Serializable

  # GitHub organization name. When set, repos can be auto-discovered.
  property org : String?
  # Explicit list of repository names (with or without org prefix).
  property repos : Array(String)?
  # Map of branch type names to their rule configuration.
  property rules : Hash(String, BranchRuleConfig)?
end

# CLI options passed via command-line flags.
struct Options
  # Operation mode: "status", "apply", "init".
  property mode : String = "status"
  # Target specific repository (full name).
  property repo : String? = nil
  # Preview changes without applying.
  property? dry_run : Bool = false
  # GitHub personal access token.
  property token : String? = nil

  def initialize
  end
end
