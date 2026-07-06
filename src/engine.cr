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
      status_print_header(types, io)
      repos.each { |repo| status_repo_line(repo, types, io) }
    end

    # Prints the status table header row and separator.
    #
    # @param types [Array(String)] Configured branch type keys
    # @param io [IO] Output stream
    private def status_print_header(types : Array(String), io : IO)
      header = "%-40s " % ["Repository"]
      types.each { |t| header += "%-24s " % [type_label(t)] }
      io.puts header
      io.puts "─" * (42 + types.size * 25)
    end

    # Prints one row of the status table for a single repository.
    #
    # Fetches rulesets and computes status for each branch type.
    # On API error prints the error message and returns early.
    #
    # @param repo [String] Full repository name (owner/name)
    # @param types [Array(String)] Configured branch type keys
    # @param io [IO] Output stream
    private def status_repo_line(repo : String, types : Array(String), io : IO)
      results = {} of String => String

      begin
        rulesets = @client.list_rulesets(repo)
        types.each { |type| results[type] = status_type_result(repo, rulesets, type) }
      rescue ex
        io.puts "%s  Error: %s" % [repo, ex.message]
        return
      end

      line = "%-40s " % [repo]
      types.each { |t| line += "%-24s " % [results.fetch(t, "✗ MISSING".colorize.red.to_s)] }
      io.puts line
    end

    # Computes the status string for a single branch type in a repo.
    #
    # Returns a colorized string showing merge method (✓/✗) and
    # checks status (+checks/~checks/-checks/MISSING).
    #
    # @param repo [String] Full repository name
    # @param rulesets [Array(Ruleset)] Existing rulesets for the repo
    # @param type [String] Branch type key
    # @return [String] Colorized status string
    private def status_type_result(repo : String, rulesets : Array(Ruleset), type : String) : String
      rule_config = @config.rules.try { |r| r[type] }
      names = type_match_names(type, rule_config)
      rs = rulesets.find(&.name.in?(names))
      id = rs.try(&.id)
      return "✗ MISSING".colorize.red.to_s unless id

      full = @client.get_ruleset(repo, id)
      pr_rule = full.rules.find { |r| r.type == "pull_request" }
      params = pr_rule.try(&.parameters)
      return "✗ MISSING".colorize.red.to_s unless params

      methods = params["allowed_merge_methods"]?.try(&.as_a)
      return "✗ MISSING".colorize.red.to_s unless methods

      method = methods.first?.to_s
      method_ok = rule_config.try(&.merge_method) == method || !rule_config.try(&.merge_method)
      status = method_ok ? "✓ #{method}".colorize.green : "✗ #{method}".colorize.red
      status = status.to_s + checks_status_label(full, rule_config.try(&.checks))
      status.to_s
    end

    # Returns a colorized checks status suffix for the status output.
    #
    # Compares actual check contexts with expected values from config.
    # Returns "+checks" (green), "~checks" (yellow), "-checks" (yellow),
    # or empty string if checks are not configured.
    #
    # @param full [Ruleset] Full ruleset with rule details
    # @param expected [Array(String)?] Expected check contexts from config
    # @return [String] Colorized checks status suffix
    private def checks_status_label(full : Ruleset, expected : Array(String)?) : String
      return "" unless expected

      checks_rule = full.rules.find { |r| r.type == "required_status_checks" }
      params = checks_rule.try(&.parameters)
      return " -checks".colorize.yellow.to_s unless params

      actual = params["required_status_checks"]?.try(&.as_a).try { |a| a.map { |c| c.as_h["context"]?.try(&.to_s) } }
      return " -checks".colorize.yellow.to_s unless actual

      actual == expected ? " +checks".colorize.green.to_s : " ~checks".colorize.yellow.to_s
    end

    # Outputs status as JSON array.
    #
    # @param repos [Array(String)] Full repository names
    # @param io [IO] Output stream (default: STDOUT)
    def status_json(repos : Array(String), io : IO = STDOUT)
      types = @config.rules.try(&.keys) || [] of String
      io.puts(JSON.build do |json|
        json.array do
          repos.each do |repo|
            json.object do
              json.field "repo", repo
              status_json_repo(json, repo, types)
            end
          end
        end
      end)
    end

    private def status_json_repo(json : JSON::Builder, repo : String, types : Array(String))
      rulesets = @client.list_rulesets(repo)
      json.field "types" do
        json.object do
          types.each do |type|
            rule_config = @config.rules.try { |r| r[type] }
            names = type_match_names(type, rule_config)
            rs = rulesets.find(&.name.in?(names))
            json.field type do
              status_json_type(json, repo, rs, rule_config)
            end
          end
        end
      end
    rescue ex
      json.field "error", ex.message
    end

    private def status_json_type(json : JSON::Builder, repo : String, rs : Ruleset?, rule_config : BranchRuleConfig?)
      id = rs.try(&.id)
      unless id
        json.object { json.field "exists", false }
        return
      end

      begin
        full = @client.get_ruleset(repo, id)
      rescue
        json.object { json.field "exists", false }
        return
      end

      pr_rule = full.rules.find { |r| r.type == "pull_request" }
      params = pr_rule.try(&.parameters)
      methods = params.try { |p| p["allowed_merge_methods"]?.try(&.as_a) }

      json.object do
        json.field "exists", true
        json.field "name", full.name

        if methods
          method = methods.first?.to_s
          expected = rule_config.try(&.merge_method)
          method_ok = expected == method || !expected
          json.field "merge_method", method
          json.field "merge_method_ok", method_ok
        end

        expected_checks = rule_config.try(&.checks)
        if expected_checks
          checks_rule = full.rules.find { |r| r.type == "required_status_checks" }
          params = checks_rule.try(&.parameters)
          actual = params.try { |p| p["required_status_checks"]?.try(&.as_a).try { |a| a.map { |c| c.as_h["context"]?.try(&.to_s) } } }
          json.field "checks_ok", actual == expected_checks
        end
      end
    end

    # Shows difference between current and desired configuration.
    #
    # For each repository: loads current rulesets, compares with desired
    # from config, and prints changes without applying them.
    #
    # @param repos [Array(String)] Full repository names
    # @param io [IO] Output stream (default: STDOUT)
    def diff(repos : Array(String), io : IO = STDOUT)
      repos.each do |repo|
        diff_repo(repo, io)
      end
    end

    # Outputs diff as JSON array.
    #
    # @param repos [Array(String)] Full repository names
    # @param io [IO] Output stream (default: STDOUT)
    def diff_json(repos : Array(String), io : IO = STDOUT)
      io.puts(JSON.build do |json|
        json.array do
          repos.each do |repo|
            diff_json_repo(json, repo)
          end
        end
      end)
    end

    private def diff_json_repo(json : JSON::Builder, repo : String)
      begin
        existing = @client.list_rulesets(repo)
      rescue ex
        json.object do
          json.field "repo", repo
          json.field "error", ex.message
        end
        return
      end

      json.object do
        json.field "repo", repo
        json.field "changes" do
          json.array do
            matched = Set(String).new

            if rules = @config.rules
              rules.each do |type, config|
                wanted = build_type_ruleset(type, config)
                names = type_match_names(type, config)
                found = existing.find(&.name.in?(names))
                matched << found.name if found

                if found
                  diff_json_update(json, repo, found, wanted)
                else
                  diff_json_create(json, wanted)
                end
              end
            end

            existing.each do |rs|
              next if rs.name.in?(matched)
              diff_json_orphan(json, rs.name)
            end
          end
        end
      end
    end

    private def diff_json_create(json : JSON::Builder, wanted : Ruleset)
      json.object do
        json.field "action", "create"
        json.field "name", wanted.name
        json.field "rules", wanted.rules.map(&.type)
        if conditions = wanted.conditions
          if ref = conditions["ref_name"]?
            if inc = ref.as_h["include"]?.try(&.as_a)
              json.field "branches", inc.map(&.to_s)
            end
          end
        end
      end
    end

    private def diff_json_update(json : JSON::Builder, repo : String, existing_rs : Ruleset, wanted : Ruleset)
      id = existing_rs.id
      unless id
        diff_json_create(json, wanted)
        return
      end

      full = begin
        @client.get_ruleset(repo, id)
      rescue
        diff_json_create(json, wanted)
        return
      end

      changes = [] of String

      existing_rules = Set.new(full.rules.map(&.type))
      wanted_rules = Set.new(wanted.rules.map(&.type))

      (wanted_rules - existing_rules).each { |r| changes << "+#{r}" }
      (existing_rules - wanted_rules).each { |r| changes << "-#{r}" }

      wanted.rules.each do |wanted_rule|
        existing_rule = full.rules.find { |r| r.type == wanted_rule.type }
        next unless existing_rule

        wanted_params = wanted_rule.parameters
        existing_params = existing_rule.parameters
        next unless wanted_params && existing_params

        wanted_params.each do |key, wanted_val|
          existing_val = existing_params[key]?
          if existing_val != wanted_val
            changes << "#{key}: #{existing_val} → #{wanted_val}"
          end
        end
      end

      json.object do
        json.field "action", changes.empty? ? "unchanged" : "update"
        json.field "name", wanted.name
        unless changes.empty?
          json.field "changes", changes
        end
      end
    end

    private def diff_json_orphan(json : JSON::Builder, name : String)
      json.object do
        json.field "action", "orphan"
        json.field "name", name
      end
    end

    # Prints diff output for a single repository.
    #
    # Compares desired rulesets from config against existing ones.
    # Shows create/update/orphan for each ruleset.
    #
    # @param repo [String] Full repository name (owner/name)
    # @param io [IO] Output stream
    private def diff_repo(repo : String, io : IO)
      begin
        existing = @client.list_rulesets(repo)
      rescue ex
        io.puts "#{repo}: Error: #{ex.message}"
        return
      end

      io.puts "=== #{repo} ==="

      matched = Set(String).new

      if rules = @config.rules
        rules.each do |type, config|
          wanted = build_type_ruleset(type, config)
          names = type_match_names(type, config)
          found = existing.find(&.name.in?(names))
          matched << found.name if found

          if found
            diff_ruleset_update(repo, found, wanted, io)
          else
            diff_ruleset_create(wanted, io)
          end
        end
      end

      existing.each do |rs|
        next if rs.name.in?(matched)
        io.puts "  #{diff_orphan(rs.name)}"
      end

      io.puts ""
    end

    # Prints a diff entry for a ruleset that should be created.
    #
    # Shows the ruleset name, rules, and target branches.
    #
    # @param wanted [Ruleset] Desired ruleset configuration
    # @param io [IO] Output stream
    private def diff_ruleset_create(wanted : Ruleset, io : IO)
      io.puts "  #{diff_add("Create ruleset '#{wanted.name}'")}"
      rules = wanted.rules.map(&.type).join(", ")
      io.puts "    rules: #{rules}"

      if conditions = wanted.conditions
        if ref = conditions["ref_name"]?
          if inc = ref.as_h["include"]?.try(&.as_a)
            io.puts "    branches: #{inc.map(&.to_s).join(", ")}"
          end
        end
      end
    end

    # Prints a diff entry for a ruleset that needs updating.
    #
    # Fetches the full ruleset, compares with desired state, and
    # lists each difference (added rules, removed rules, param changes).
    #
    # @param repo [String] Full repository name
    # @param existing_rs [Ruleset] Existing ruleset (from list endpoint)
    # @param wanted [Ruleset] Desired ruleset configuration
    # @param io [IO] Output stream
    private def diff_ruleset_update(repo : String, existing_rs : Ruleset, wanted : Ruleset, io : IO)
      id = existing_rs.id
      unless id
        io.puts "  #{diff_add("Create ruleset '#{wanted.name}'")}"
        return
      end

      begin
        full = @client.get_ruleset(repo, id)
      rescue ex
        io.puts "  #{wanted.name}: Error fetching full ruleset: #{ex.message}"
        return
      end

      changes = [] of String

      existing_rules = Set.new(full.rules.map(&.type))
      wanted_rules = Set.new(wanted.rules.map(&.type))

      added = wanted_rules - existing_rules
      removed = existing_rules - wanted_rules

      unless added.empty? && removed.empty?
        added.each { |r| changes << diff_add(r) }
        removed.each { |r| changes << diff_remove(r) }
      end

      wanted.rules.each do |wanted_rule|
        existing_rule = full.rules.find { |r| r.type == wanted_rule.type }
        next unless existing_rule

        wanted_params = wanted_rule.parameters
        existing_params = existing_rule.parameters
        next unless wanted_params && existing_params

        wanted_params.each do |key, wanted_val|
          existing_val = existing_params[key]?
          if existing_val != wanted_val
            changes << "#{key}: #{existing_val} → #{wanted_val}"
          end
        end
      end

      if changes.empty?
        io.puts "  #{wanted.name}: #{diff_unchanged("no changes")}"
      else
        io.puts "  #{diff_change("Update ruleset '#{wanted.name}'")}"
        changes.each { |c| io.puts "    #{c}" }
      end
    end

    # Formats text as a green addition for diff output.
    #
    # @param text [String] Description of the addition
    # @return [String] Green colorized "+ text"
    private def diff_add(text : String) : String
      "+ #{text}".colorize.green.to_s
    end

    # Formats text as a red removal for diff output.
    #
    # @param text [String] Description of the removal
    # @return [String] Red colorized "- text"
    private def diff_remove(text : String) : String
      "- #{text}".colorize.red.to_s
    end

    # Formats text as a yellow change for diff output.
    #
    # @param text [String] Description of the change
    # @return [String] Yellow colorized "~ text"
    private def diff_change(text : String) : String
      "~ #{text}".colorize.yellow.to_s
    end

    # Formats text as a dimmed unchanged entry for diff output.
    #
    # @param text [String] Description (e.g. "no changes")
    # @return [String] Dimmed "  text"
    private def diff_unchanged(text : String) : String
      "  #{text}".colorize.dim.to_s
    end

    # Formats an orphan ruleset entry for diff output.
    #
    # @param name [String] Ruleset name
    # @return [String] Red colorized "- Orphan ruleset 'name'"
    private def diff_orphan(name : String) : String
      "- Orphan ruleset '#{name}'".colorize.red.to_s
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

    # Outputs apply result as JSON array.
    #
    # @param repos [Array(String)] Full repository names
    # @param dry_run [Bool] Preview only (default: false)
    # @param io [IO] Output stream (default: STDOUT)
    def apply_json(repos : Array(String), dry_run : Bool = false, io : IO = STDOUT)
      io.puts(JSON.build do |json|
        json.array do
          repos.each do |repo|
            apply_json_repo(json, repo, dry_run)
          end
        end
      end)
    end

    private def apply_json_repo(json : JSON::Builder, repo : String, dry_run : Bool)
      begin
        existing = @client.list_rulesets(repo)
      rescue ex
        json.object do
          json.field "repo", repo
          json.field "error", ex.message
        end
        return
      end

      json.object do
        json.field "repo", repo
        json.field "results" do
          json.array do
            if rules = @config.rules
              rules.each do |type, config|
                wanted = build_type_ruleset(type, config)
                names = type_match_names(type, config)
                found = existing.find(&.name.in?(names))
                apply_json_ruleset(json, repo, found, wanted, dry_run)
              end
            end
          end
        end
      end
    end

    private def apply_json_ruleset(json : JSON::Builder, repo : String, existing : Ruleset?, wanted : Ruleset, dry_run : Bool)
      if dry_run || (!existing || !existing.id)
        action = (!existing || !existing.id) ? "create" : "update"
        json.object do
          json.field "action", action
          json.field "name", wanted.name
          json.field "dry_run", true if dry_run
          json.field "id", existing.id if existing && existing.id
        end
        return
      end

      json.object do
        json.field "action", "update"
        json.field "name", wanted.name
        json.field "id", existing.id
      end
    end

    # Applies desired rulesets for a single repository.
    #
    # Iterates over ALL configured branch types and creates or
    # updates each matching ruleset via the GitHub API.
    #
    # @param repo [String] Full repository name (owner/name)
    # @param dry_run [Bool] Preview only without API mutations
    # @param io [IO] Output stream
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

    # Builds a complete Ruleset struct for API submission.
    #
    # Always includes deletion, non_fast_forward, and pull_request
    # rules. Adds required_status_checks only when checks are configured.
    #
    # @param name [String] Ruleset display name
    # @param config [BranchRuleConfig] Branch type configuration
    # @param ref_include [Array(String)] Ref patterns to include
    # @return [Ruleset] Ruleset ready for API submission
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

    # Builds parameters for the pull_request rule.
    #
    # Sets up required approving review count, stale review dismissal,
    # code owner review, and optionally the allowed merge methods.
    #
    # @param method [String?] Allowed merge method (nil = no restriction)
    # @return [Hash(String, JSON::Any)] Pull request rule parameters
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

    # Builds parameters for the required_status_checks rule.
    #
    # Creates the required status check contexts list and enables
    # strict policy (new commits require re-check).
    #
    # @param checks [Array(String)] Required check context names
    # @return [Hash(String, JSON::Any)] Required status checks parameters
    private def required_status_checks_params(checks : Array(String)) : Hash(String, JSON::Any)
      {
        "required_status_checks"               => JSON::Any.new(checks.map { |c| JSON::Any.new({"context" => JSON::Any.new(c)}) }),
        "strict_required_status_checks_policy" => JSON::Any.new(true),
      }
    end

    # Creates or updates a single ruleset via the GitHub API.
    #
    # In dry-run mode prints intended action without API calls.
    # If existing has an ID, calls update; otherwise calls create.
    #
    # @param repo [String] Full repository name
    # @param existing [Ruleset?] Existing ruleset (nil if none)
    # @param wanted [Ruleset] Desired ruleset configuration
    # @param dry_run [Bool] Preview only without API mutations
    # @param io [IO] Output stream
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
