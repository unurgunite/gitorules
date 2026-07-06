require "colorize"

module Gitorules
  # Evaluates and applies ruleset configuration across repositories.
  #
  # Compares current GitHub rulesets against the desired state from
  # `.gitorules.yml` and reports discrepancies or applies changes.
  class Engine
    @client : GitHubClient
    @config : Config

    # @param client [GitHubClient] Authenticated API client
    # @param config [Config] Parsed configuration
    def initialize(@client : GitHubClient, @config : Config)
    end

    # Prints a status table for all given repositories.
    #
    # Shows each configured branch type as a column with merge method
    # and checks status. Colorized: green ✓ / red ✗ / yellow ✗.
    #
    # @param repos [Array(String)] Full repository names
    # @param io [IO] Output stream (default: STDOUT)
    def status(repos : Array(String), io : IO = STDOUT)
      types = @config.rules.try(&.keys) || [] of String

      header = "%-40s " % ["Repository"]
      types.each { |t| header += "%-24s " % [type_label(t)] }
      io.puts header
      io.puts "─" * (42 + types.size * 25)

      repos.each do |repo|
        results = {} of String => String

        begin
          rulesets = @client.list_rulesets(repo)

          types.each do |type|
            rule_config = @config.rules.try { |r| r[type] }
            names = type_match_names(type, rule_config)
            if rs = rulesets.find(&.name.in?(names))
              if rs_id = rs.id
                full = @client.get_ruleset(repo, rs_id)
                if pr_rule = full.rules.find { |r| r.type == "pull_request" }
                  if params = pr_rule.parameters
                    if methods = params["allowed_merge_methods"]?.try(&.as_a)
                      method = methods.first?.to_s
                      method_ok = rule_config.try(&.merge_method) == method || !rule_config.try(&.merge_method)
                      checks_ok = if rule_config.try(&.checks)
                                    full.rules.any? { |r| r.type == "required_status_checks" }
                                  else
                                    true
                                  end
                      method_status = method_ok ? "✓ #{method}" : "✗ #{method}"
                      status = method_ok ? method_status.colorize.green : method_status.colorize.red
                      if rule_config.try(&.checks)
                        check_status = checks_ok ? " +checks".colorize.green : " -checks".colorize.yellow
                        status = status.to_s + check_status.to_s
                      end
                      results[type] = status.to_s
                    end
                  end
                end
              end
            else
              results[type] = "✗ MISSING".colorize.red.to_s
            end
          end
        rescue ex
          io.puts "%s  Error: %s" % [repo, ex.message]
          next
        end

        line = "%-40s " % [repo]
        types.each { |t| line += "%-24s " % [results.fetch(t, "✗ MISSING".colorize.red.to_s)] }
        io.puts line
      end
    end

    # Applies desired ruleset configuration to repositories.
    #
    # Creates or updates rulesets for ALL configured branch types.
    # In dry-run mode prints intended actions without API calls.
    #
    # @param repos [Array(String)] Full repository names
    # @param dry_run [Bool] Preview only (default: false)
    # @param io [IO] Output stream (default: STDOUT)
    def apply(repos : Array(String), dry_run : Bool = false, io : IO = STDOUT)
      repos.each do |repo|
        apply_repo(repo, dry_run, io)
      end
    end

    private def apply_repo(repo : String, dry_run : Bool, io : IO)
      existing = @client.list_rulesets(repo)

      if rules = @config.rules
        rules.each do |type, config|
          wanted = build_type_ruleset(type, config)
          names = type_match_names(type, config)
          found = existing.find(&.name.in?(names))
          apply_ruleset(repo, found, wanted, dry_run, io)
        end
      end
    end

    # Generates the GitHub ruleset display name for a branch type.
    #
    # Uses config `name` if set, otherwise derives from type key:
    #   "default_branch" → "master"
    #   "release"        → "Release branches — squash only"
    #   "system"         → "System branches"
    #   "hotfix"         → "Hotfix branches"
    #
    # @param type [String] Config key (e.g. "default_branch", "release")
    # @return [String] Human-readable ruleset name
    private def type_display_name(type : String, config : BranchRuleConfig? = nil) : String
      if config && (custom = config.name)
        return custom
      end

      case type
      when "default_branch" then "master"
      when "release"        then "Release branches — squash only"
      else                       "#{type.capitalize} branches"
      end
    end

    # Returns the set of ruleset names to match when looking up
    # existing rulesets. Includes legacy names for backward compat.
    #
    # @param type [String] Config key
    # @param config [BranchRuleConfig?] Optional config (for custom name)
    # @return [Set(String)] Names to match
    private def type_match_names(type : String, config : BranchRuleConfig? = nil) : Set(String)
      names = Set(String).new
      names << type_display_name(type, config)

      case type
      when "default_branch"
        names << "Master - merge commits only"
        names << "master"
      when "release"
        names << "Release branches - squash only"
      end

      names
    end

    # Generates the ref include patterns for a branch type.
    #
    # Uses config `pattern` if set, otherwise derives from type:
    #   "default_branch" → "refs/heads/master"
    #   "release"        → "refs/heads/v*" (default pattern)
    #   "system"         → "refs/heads/system/*" (default pattern)
    #   custom           → "refs/heads/{type}/*" (default pattern)
    #
    # @param type [String] Config key
    # @param config [BranchRuleConfig] Branch type config
    # @return [Array(String)] Ref patterns to include
    private def type_refs(type : String, config : BranchRuleConfig) : Array(String)
      if config.pattern
        return ["refs/heads/#{config.pattern}"]
      end

      pattern = case type
                when "default_branch" then "master"
                when "release"        then "v*"
                else                       "#{type}/*"
                end

      ["refs/heads/#{pattern}"]
    end

    # Builds a complete Ruleset for a given branch type.
    #
    # Delegates to the generic `#build_ruleset` with the appropriate
    # display name and ref patterns for the type.
    #
    # @param type [String] Config key
    # @param config [BranchRuleConfig] Branch type config
    # @return [Ruleset] Ruleset ready for API submission
    private def build_type_ruleset(type : String, config : BranchRuleConfig) : Ruleset
      name = type_display_name(type, config)
      refs = type_refs(type, config)
      build_ruleset(name, config, refs)
    end

    private def build_ruleset(name : String, config : BranchRuleConfig, ref_include : Array(String)) : Ruleset
      rules = [] of Rule
      rules << Rule.new("deletion")
      rules << Rule.new("non_fast_forward")
      rules << Rule.new("pull_request", merge_method_params(config.merge_method))

      if checks = config.checks
        rules << Rule.new("required_status_checks", required_status_checks_params(checks))
      end

      Ruleset.new(
        name: name,
        enforcement: "active",
        target: "branch",
        conditions: {
          "ref_name" => JSON::Any.new({
            "include" => JSON::Any.new(ref_include.map { |r| JSON::Any.new(r) }),
            "exclude" => JSON::Any.new([] of JSON::Any),
          }),
        },
        rules: rules,
      )
    end

    private def merge_method_params(method : String?) : Hash(String, JSON::Any)
      params = {
        "required_approving_review_count"   => JSON::Any.new(0_i64),
        "dismiss_stale_reviews_on_push"     => JSON::Any.new(false),
        "require_code_owner_review"         => JSON::Any.new(false),
        "require_last_push_approval"        => JSON::Any.new(false),
        "required_review_thread_resolution" => JSON::Any.new(false),
        "required_reviewers"                => JSON::Any.new([] of JSON::Any),
      }

      if method
        params["allowed_merge_methods"] = JSON::Any.new([JSON::Any.new(method)])
      end

      params
    end

    private def required_status_checks_params(checks : Array(String)) : Hash(String, JSON::Any)
      {
        "required_status_checks"               => JSON::Any.new(checks.map { |c| JSON::Any.new({"context" => JSON::Any.new(c)}) }),
        "strict_required_status_checks_policy" => JSON::Any.new(true),
      }
    end

    private def apply_ruleset(repo : String, existing : Ruleset?, wanted : Ruleset, dry_run : Bool, io : IO)
      if dry_run
        if existing && existing.id
          io.puts "#{repo}: Would update ruleset '#{wanted.name}' (ID #{existing.id})"
        else
          io.puts "#{repo}: Would create ruleset '#{wanted.name}'"
        end
        return
      end

      if existing && (id = existing.id)
        @client.update_ruleset(repo, id, wanted)
        io.puts "#{repo}: Updated ruleset '#{wanted.name}'"
      else
        @client.create_ruleset(repo, wanted)
        io.puts "#{repo}: Created ruleset '#{wanted.name}'"
      end
    end

    # Returns a human-readable label for status column headers.
    #
    # @param type [String] Config key
    # @return [String] Short label for the column header
    private def type_label(type : String) : String
      case type
      when "default_branch" then "default"
      when "release"        then "release"
      else                       type
      end
    end
  end
end
