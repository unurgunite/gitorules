require "colorize"

module Gitorules
  class Engine
    @client : GitHubClient
    @config : Config

    def initialize(@client : GitHubClient, @config : Config)
    end

    def status(repos : Array(String), quiet : Bool = false, io : IO = STDOUT)
      types = @config.all_type_keys
      status_print_header(types, io) unless quiet
      total = repos.size
      is_tty = colorize?(io)
      outputs = Concurrent.map_ordered(repos) do |repo, idx|
        prefix = "[#{idx + 1}/#{total}] "
        buf = TtyMemory.new(is_tty)
        failed = false
        begin
          status_repo_line(repo, types, buf, prefix, quiet)
        rescue
          buf.puts error_io_line(repo, types, prefix, buf) unless quiet
          failed = true
        end
        {buf.to_s, failed}
      end
      errors = 0
      outputs.each do |(text, failed)|
        io.print(text)
        errors += 1 if failed
      end
      n = repos.size
      if errors == 0
        io.puts "All rulesets up to date"
      else
        io.puts "Done: #{n} repos processed, #{errors} error(s)"
      end
    end

    private def status_print_header(types : Array(String), io : IO)
      header = pad_to("Repository", 40) + " "
      types.each { |t| header += pad_to(type_label(t), 24) + " " }
      io.puts header
      io.puts "─" * (41 + types.size * 25)
    end

    private def status_repo_line(repo : String, types : Array(String), io : IO, prefix : String = "", quiet : Bool = false)
      results = {} of String => String
      rules = @config.rules_for(repo)

      begin
        rulesets = @client.list_rulesets(repo)
        types.each { |type| results[type] = status_type_result(repo, rulesets, type, rules, io) }
      rescue
        io.puts error_io_line(repo, types, prefix, io) unless quiet
        return
      end

      line = pad_to(repo, 40) + " "
      types.each { |t| line += pad_to(results.fetch(t, red("✗ MISSING", io)), 24) + " " }
      io.puts "#{prefix}#{line}" unless quiet
    end

    private def error_io_line(repo : String, types : Array(String), prefix : String = "", io : IO = STDOUT) : String
      line = pad_to(repo, 40) + " "
      types.each { |_| line += pad_to(red("ERR", io), 24) + " " }
      "#{prefix}#{line}"
    end

    private def status_type_result(repo : String, rulesets : Array(Ruleset), type : String, rules : Hash(String, BranchRuleConfig)?, io : IO) : String
      rule_config = rules.try { |r| r[type] }
      names = type_match_names(type, rule_config)
      rs = rulesets.find(&.name.in?(names))
      id = rs.try(&.id)
      return red("✗ MISSING", io) unless id

      full = @client.get_ruleset(repo, id)
      pr_rule = full.rules.find { |r| r.type == "pull_request" }
      params = pr_rule.try(&.parameters)
      return red("✗ MISSING", io) unless params

      methods = params["allowed_merge_methods"]?.try(&.as_a)
      return red("✗ MISSING", io) unless methods

      method = methods.first?.to_s
      method_ok = rule_config.try(&.merge_method) == method || !rule_config.try(&.merge_method)
      status = method_ok ? green("✓ #{method}", io) : red("✗ #{method}", io)
      status = status.to_s + checks_status_label(full, rule_config, io)
      status.to_s
    end

    private def checks_status_label(full : Ruleset, config : BranchRuleConfig?, io : IO) : String
      expected = config.try(&.checks)
      return "" unless expected

      checks_rule = full.rules.find { |r| r.type == "required_status_checks" }
      params = checks_rule.try(&.parameters)
      return yellow(" -checks", io) unless params

      actual = params["required_status_checks"]?.try(&.as_a).try { |a| a.map { |c| c.as_h["context"]?.try(&.to_s) } }
      return yellow(" -checks", io) unless actual

      if config.try(&.glob_checks?) && (cfg = config)
        actual_str = actual.compact
        cfg.checks_match?(actual_str) ? green(" +checks", io) : yellow(" ~checks", io)
      else
        actual == expected ? green(" +checks", io) : yellow(" ~checks", io)
      end
    end

    def status_json(repos : Array(String), io : IO = STDOUT)
      types = @config.all_type_keys
      results = Concurrent.map_ordered(repos) do |repo, _idx|
        status_repo_json_string(repo, types)
      end
      io.puts("[#{results.join(",")}]")
    end

    private def status_repo_json_string(repo : String, types : Array(String)) : String
      JSON.build do |json|
        json.object do
          json.field "repo", repo
          status_json_repo(json, repo, types)
        end
      end
    end

    private def status_json_repo(json : JSON::Builder, repo : String, types : Array(String))
      rules = @config.rules_for(repo)
      rulesets = @client.list_rulesets(repo)
      json.field "types" do
        json.object do
          types.each do |type|
            rule_config = rules.try { |r| r[type] }
            names = type_match_names(type, rule_config)
            rs = rulesets.find(&.name.in?(names))
            json.field type do
              status_json_type(json, repo, rs, rule_config, type)
            end
          end
        end
      end
    rescue ex
      json.field "resource", ""
      json.field "action", "error"
      json.field "changes", [] of String
      json.field "error", ex.message
    end

    private def status_json_type(json : JSON::Builder, repo : String, rs : Ruleset?, rule_config : BranchRuleConfig?, type : String? = nil)
      wanted_name = type ? type_display_name(type, rule_config) : rs.try(&.name) || "unknown"
      if rules_missing_for_repo?(repo)
        write_skip_status_entry(json, rs, wanted_name)
        return
      end
      id = rs.try(&.id)
      unless id
        write_create_status_entry(json, wanted_name)
        return
      end
      full = fetch_full_ruleset(json, repo, id, rs, wanted_name)
      return unless full
      write_full_status_entry(json, full, rule_config)
    end

    private def write_skip_status_entry(json : JSON::Builder, rs : Ruleset?, wanted_name : String)
      resource = rs.try(&.name) || wanted_name
      json.object do
        json.field "exists", !rs.nil?
        json.field "name", rs.name if rs
        json.field "resource", resource
        json.field "action", "skip"
        json.field "changes", [] of String
      end
    end

    private def write_create_status_entry(json : JSON::Builder, wanted_name : String)
      json.object do
        json.field "exists", false
        json.field "resource", wanted_name
        json.field "action", "create"
        json.field "changes", [] of String
      end
    end

    private def fetch_full_ruleset(json : JSON::Builder, repo : String, id : Int64, rs : Ruleset?, wanted_name : String) : Ruleset?
      @client.get_ruleset(repo, id)
    rescue ex
      json.object do
        json.field "exists", false
        json.field "resource", rs.try(&.name) || wanted_name
        json.field "action", "error"
        json.field "changes", [ex.message.to_s]
      end
      nil
    end

    private def resolve_method_ok(methods : Array(JSON::Any)?, method : String?, expected : String?) : Bool?
      return unless methods
      expected.nil? || expected == method
    end

    private def resolve_checks_ok(full : Ruleset, rule_config : BranchRuleConfig?, expected_checks : Array(String)?) : {Bool?, Array(String)}
      return {nil, [] of String} unless expected_checks
      checks_rule = full.rules.find { |r| r.type == "required_status_checks" }
      cparams = checks_rule.try(&.parameters)
      actual = cparams.try { |p| p["required_status_checks"]?.try(&.as_a).try { |a| a.map { |c| c.as_h["context"]?.try(&.to_s) } } }
      actual_str = actual.try(&.compact) || [] of String
      checks_ok = compare_check_contexts(rule_config, expected_checks, actual, actual_str)
      {checks_ok, actual_str}
    end

    private def compare_check_contexts(rule_config : BranchRuleConfig?, expected_checks : Array(String), actual : Array(String?)?, actual_str : Array(String)) : Bool
      if rule_config.try(&.glob_checks?)
        rule_config.try(&.checks_match?(actual_str)) || false
      else
        actual == expected_checks
      end
    end

    private def status_change_descriptions(method_ok : Bool?, method : String?, expected : String?, checks_ok : Bool?, expected_checks : Array(String)?, actual_str : Array(String)) : Array(String)
      changes = [] of String
      if method_ok == false && method
        changes << "merge_method: expected #{expected || "any"}, got #{method}"
      end
      if checks_ok == false
        changes << "checks: mismatch (expected #{expected_checks}, got #{actual_str.empty? ? "none" : actual_str.join(", ")})"
      end
      changes
    end

    private def write_full_status_entry(json : JSON::Builder, full : Ruleset, rule_config : BranchRuleConfig?)
      pr_rule = full.rules.find { |r| r.type == "pull_request" }
      params = pr_rule.try(&.parameters)
      methods = params.try { |p| p["allowed_merge_methods"]?.try(&.as_a) }

      method = methods.try(&.first?.to_s)
      expected = rule_config.try(&.merge_method)
      method_ok = resolve_method_ok(methods, method, expected)

      expected_checks = rule_config.try(&.checks)
      checks_ok, actual_str = resolve_checks_ok(full, rule_config, expected_checks)

      changes = status_change_descriptions(method_ok, method, expected, checks_ok, expected_checks, actual_str)
      action = (method_ok == false || checks_ok == false) ? "update" : "unchanged"

      json.object do
        json.field "exists", true
        json.field "name", full.name
        json.field "resource", full.name

        if methods && method
          json.field "merge_method", method
          json.field "merge_method_ok", method_ok
        end

        if expected_checks
          json.field "checks_ok", checks_ok
        end
        json.field "action", action
        json.field "changes", changes
      end
    end

    private def rules_missing_for_repo?(repo : String) : Bool
      @config.rules_for(repo).nil?
    end

    def diff(repos : Array(String), quiet : Bool = false, io : IO = STDOUT)
      total = repos.size
      is_tty = colorize?(io)
      outputs = Concurrent.map_ordered(repos) do |repo, idx|
        prefix = "[#{idx + 1}/#{total}] "
        buf = TtyMemory.new(is_tty)
        begin
          diff_repo(repo, buf, prefix, quiet)
        rescue ex
          buf.puts "#{prefix}#{repo}: Error: #{ex.message}" unless quiet
        end
        buf.to_s
      end
      outputs.each { |text| io.print(text) }
      io.puts "Done: #{repos.size} repos processed"
    end

    def diff_json(repos : Array(String), io : IO = STDOUT)
      results = Concurrent.map_ordered(repos) do |repo, _idx|
        diff_repo_json_string(repo)
      end
      io.puts("[#{results.join(",")}]")
    end

    private def diff_repo_json_string(repo : String) : String
      JSON.build do |json|
        write_repo_json_entry(json, repo)
      end
    end

    private def write_repo_json_entry(json : JSON::Builder, repo : String)
      diff_json_repo(json, repo)
    rescue ex
      json.object do
        json.field "repo", repo
        json.field "resource", ""
        json.field "action", "error"
        json.field "changes", [] of String
        json.field "error", ex.message
      end
    end

    private def diff_json_repo(json : JSON::Builder, repo : String)
      begin
        existing = @client.list_rulesets(repo)
      rescue ex
        json.object do
          json.field "repo", repo
          json.field "resource", ""
          json.field "action", "error"
          json.field "changes", [] of String
          json.field "error", ex.message
        end
        return
      end

      json.object do
        json.field "repo", repo
        json.field "changes" do
          json.array do
            matched = Set(String).new

            if repo_rules = @config.rules_for(repo)
              repo_rules.each do |type, config|
                wanted = build_type_ruleset(type, config)
                names = type_match_names(type, config)
                found = existing.find(&.name.in?(names))
                matched << found.name if found

                if found
                  diff_json_update(json, repo, found, wanted, config)
                else
                  diff_json_create(json, wanted)
                end
              end
            else
              json.object do
                json.field "action", "skip"
                json.field "name", ""
                json.field "resource", ""
                json.field "changes", ["no rules configured for repo"]
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
        json.field "resource", wanted.name
        json.field "changes", [] of String
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

    private def diff_json_update(json : JSON::Builder, repo : String, existing_rs : Ruleset, wanted : Ruleset, config : BranchRuleConfig)
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
      removed = existing_rules - wanted_rules
      if config.glob_checks?
        removed.delete("required_status_checks")
      end
      removed.each { |r| changes << "-#{r}" }

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

      if config.glob_checks? && full.rules.any? { |r| r.type == "required_status_checks" }
        changes << "required_status_checks (matched by glob pattern)"
      end

      json.object do
        json.field "action", changes.empty? ? "unchanged" : "update"
        json.field "name", wanted.name
        json.field "resource", wanted.name
        json.field "changes", changes
      end
    end

    private def diff_json_orphan(json : JSON::Builder, name : String)
      json.object do
        json.field "action", "orphan"
        json.field "name", name
        json.field "resource", name
        json.field "changes", [] of String
      end
    end

    private def diff_repo(repo : String, io : IO, prefix : String = "", quiet : Bool = false)
      begin
        existing = @client.list_rulesets(repo)
      rescue ex
        io.puts "#{prefix}#{repo}: Error: #{ex.message}" unless quiet
        return
      end

      io.puts "#{prefix}=== #{repo} ===" unless quiet

      matched = Set(String).new

      if repo_rules = @config.rules_for(repo)
        repo_rules.each do |type, config|
          wanted = build_type_ruleset(type, config)
          names = type_match_names(type, config)
          found = existing.find(&.name.in?(names))
          matched << found.name if found

          if found
            diff_ruleset_update(repo, found, wanted, config, io, quiet)
          else
            diff_ruleset_create(wanted, io, quiet)
          end
        end
      end

      existing.each do |rs|
        next if rs.name.in?(matched)
        io.puts "  #{diff_orphan(rs.name, io)}" unless quiet
      end

      io.puts "" unless quiet
    end

    private def diff_ruleset_create(wanted : Ruleset, io : IO, quiet : Bool = false)
      io.puts "  #{diff_add("Create ruleset '#{wanted.name}'", io)}" unless quiet
      rules = wanted.rules.map(&.type).join(", ")
      io.puts "    rules: #{rules}" unless quiet

      if conditions = wanted.conditions
        if ref = conditions["ref_name"]?
          if inc = ref.as_h["include"]?.try(&.as_a)
            io.puts "    branches: #{inc.map(&.to_s).join(", ")}" unless quiet
          end
        end
      end
    end

    private def diff_ruleset_update(repo : String, existing_rs : Ruleset, wanted : Ruleset, config : BranchRuleConfig, io : IO, quiet : Bool = false)
      id = existing_rs.id
      unless id
        diff_ruleset_create(wanted, io, quiet)
        return
      end

      begin
        full = @client.get_ruleset(repo, id)
      rescue ex
        io.puts "  #{wanted.name}: Error fetching full ruleset: #{ex.message}" unless quiet
        return
      end

      changes = diff_rule_changes(full, wanted, config, io)

      if config.glob_checks? && full.rules.any? { |r| r.type == "required_status_checks" }
        changes << diff_unchanged("required_status_checks (matched by glob pattern, left unchanged)", io)
      end

      if changes.empty?
        io.puts "  #{wanted.name}: #{diff_unchanged("no changes", io)}" unless quiet
      else
        io.puts "  #{diff_change("Update ruleset '#{wanted.name}'", io)}" unless quiet
        changes.each { |c| io.puts "    #{c}" } unless quiet
      end
    end

    private def diff_rule_changes(full : Ruleset, wanted : Ruleset, config : BranchRuleConfig, io : IO) : Array(String)
      changes = [] of String

      existing_rules = Set.new(full.rules.map(&.type))
      wanted_rules = Set.new(wanted.rules.map(&.type))

      added = wanted_rules - existing_rules
      removed = existing_rules - wanted_rules

      if config.glob_checks?
        removed.delete("required_status_checks")
      end

      unless added.empty? && removed.empty?
        added.each { |r| changes << diff_add(r, io) }
        removed.each { |r| changes << diff_remove(r, io) }
      end

      wanted.rules.each do |wanted_rule|
        existing_rule = full.rules.find { |r| r.type == wanted_rule.type }
        next unless existing_rule

        changes.concat(diff_rule_param_changes(existing_rule, wanted_rule))
      end

      changes
    end

    private def diff_rule_param_changes(existing_rule : Rule, wanted_rule : Rule) : Array(String)
      changes = [] of String

      wanted_params = wanted_rule.parameters
      existing_params = existing_rule.parameters
      return changes unless wanted_params && existing_params

      wanted_params.each do |key, wanted_val|
        existing_val = existing_params[key]?
        if existing_val != wanted_val
          changes << "#{key}: #{existing_val} → #{wanted_val}"
        end
      end

      changes
    end

    private def diff_add(text : String, io : IO) : String
      green("+ #{text}", io)
    end

    private def diff_remove(text : String, io : IO) : String
      red("- #{text}", io)
    end

    private def diff_change(text : String, io : IO) : String
      yellow("~ #{text}", io)
    end

    private def diff_unchanged(text : String, io : IO) : String
      dim("  #{text}", io)
    end

    private def diff_orphan(name : String, io : IO) : String
      red("- Orphan ruleset '#{name}'", io)
    end

    def apply(repos : Array(String), dry_run : Bool = false, quiet : Bool = false, io : IO = STDOUT)
      total = repos.size
      is_tty = colorize?(io)
      outputs = Concurrent.map_ordered(repos) do |repo, idx|
        prefix = "[#{idx + 1}/#{total}] "
        buf = TtyMemory.new(is_tty)
        failed = false
        begin
          apply_repo(repo, dry_run, buf, prefix, quiet)
        rescue ex
          buf.puts "#{prefix}#{repo}: Error: #{ex.message}" unless quiet
          failed = true
        end
        {buf.to_s, failed}
      end
      errors = 0
      outputs.each do |(text, failed)|
        io.print(text)
        errors += 1 if failed
      end
      n = repos.size
      io.puts "Done: #{n} repos processed, #{errors} error(s)"
    end

    def apply_json(repos : Array(String), dry_run : Bool = false, io : IO = STDOUT)
      results = Concurrent.map_ordered(repos) do |repo, _idx|
        apply_repo_json_string(repo, dry_run)
      end
      io.puts("[#{results.join(",")}]")
    end

    private def apply_repo_json_string(repo : String, dry_run : Bool) : String
      JSON.build do |json|
        write_apply_json_entry(json, repo, dry_run)
      end
    end

    private def write_apply_json_entry(json : JSON::Builder, repo : String, dry_run : Bool)
      apply_json_repo(json, repo, dry_run)
    rescue ex
      json.object do
        json.field "repo", repo
        json.field "resource", ""
        json.field "action", "error"
        json.field "changes", [] of String
        json.field "error", ex.message
      end
    end

    private def apply_json_repo(json : JSON::Builder, repo : String, dry_run : Bool)
      begin
        existing = @client.list_rulesets(repo)
      rescue ex
        json.object do
          json.field "repo", repo
          json.field "resource", ""
          json.field "action", "error"
          json.field "changes", [] of String
          json.field "error", ex.message
        end
        return
      end

      json.object do
        json.field "repo", repo
        json.field "results" do
          json.array do
            if repo_rules = @config.rules_for(repo)
              repo_rules.each do |type, config|
                wanted = build_type_ruleset(type, config)
                names = type_match_names(type, config)
                found = existing.find(&.name.in?(names))
                apply_json_ruleset(json, repo, found, wanted, config, dry_run)
              end
            else
              json.object do
                json.field "action", "skip"
                json.field "name", ""
                json.field "resource", ""
                json.field "changes", ["no rules configured for repo"]
              end
            end
          end
        end
      end
    end

    private def apply_json_ruleset(json : JSON::Builder, repo : String, existing : Ruleset?, wanted : Ruleset, config : BranchRuleConfig, dry_run : Bool)
      if dry_run || (!existing || !existing.id)
        action = (!existing || !existing.id) ? "create" : "update"
        json.object do
          json.field "action", action
          json.field "name", wanted.name
          json.field "resource", wanted.name
          json.field "changes", [] of String
          json.field "dry_run", true if dry_run
          json.field "id", existing.id if existing && existing.id
          json_apply_checks_skipped(json, action, config)
        end
        return
      end

      json.object do
        json.field "action", "update"
        json.field "name", wanted.name
        json.field "resource", wanted.name
        json.field "changes", [] of String
        json.field "id", existing.id
      end
    end

    private def json_apply_checks_skipped(json : JSON::Builder, action : String, config : BranchRuleConfig)
      if action == "create" && config.glob_checks?
        json.field "checks_skipped", true
      end
    end

    private def apply_repo(repo : String, dry_run : Bool, io : IO, prefix : String = "", quiet : Bool = false)
      existing = @client.list_rulesets(repo)

      if repo_rules = @config.rules_for(repo)
        repo_rules.each do |type, config|
          wanted = build_type_ruleset(type, config)
          names = type_match_names(type, config)
          found = existing.find(&.name.in?(names))
          apply_ruleset(repo, found, wanted, config, dry_run, io, prefix, quiet)
        end
      end
    end

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
        unless config.glob_checks?
          rules << Rule.new("required_status_checks", required_status_checks_params(checks))
        end
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

    private def apply_ruleset(repo : String, existing : Ruleset?, wanted : Ruleset, config : BranchRuleConfig, dry_run : Bool, io : IO, prefix : String = "", quiet : Bool = false)
      if dry_run
        apply_ruleset_dry_run(repo, existing, wanted, io, prefix, quiet)
        return
      end

      if existing && (id = existing.id)
        preserve_glob_checks(repo, id, wanted, config)
        @client.update_ruleset(repo, id, wanted)
        io.puts "#{prefix}#{repo}: Updated ruleset '#{wanted.name}'" unless quiet
      else
        apply_ruleset_create_message(repo, wanted, config, io, prefix, quiet)
        @client.create_ruleset(repo, wanted)
      end
    end

    private def apply_ruleset_dry_run(repo : String, existing : Ruleset?, wanted : Ruleset, io : IO, prefix : String, quiet : Bool)
      if existing && existing.id
        io.puts "#{prefix}#{repo}: Would update ruleset '#{wanted.name}' (ID #{existing.id})" unless quiet
      else
        io.puts "#{prefix}#{repo}: Would create ruleset '#{wanted.name}'" unless quiet
      end
    end

    private def apply_ruleset_create_message(repo : String, wanted : Ruleset, config : BranchRuleConfig, io : IO, prefix : String, quiet : Bool)
      if config.glob_checks?
        io.puts "#{prefix}#{repo}: Created ruleset '#{wanted.name}' (checks skipped — glob patterns can't be applied on create)" unless quiet
      else
        io.puts "#{prefix}#{repo}: Created ruleset '#{wanted.name}'" unless quiet
      end
    end

    private def preserve_glob_checks(repo : String, id : Int64, wanted : Ruleset, config : BranchRuleConfig)
      return unless config.glob_checks?

      full = @client.get_ruleset(repo, id)
      if existing_checks = full.rules.find { |r| r.type == "required_status_checks" }
        wanted.rules << existing_checks unless wanted.rules.any? { |r| r.type == "required_status_checks" }
      end
    rescue
    end

    private def pad_to(text : String, width : Int32) : String
      plain = text.gsub(/\e\[[0-9;]*m/, "")
      text + " " * Math.max(0, width - plain.size)
    end

    private def type_label(type : String) : String
      case type
      when "default_branch" then "default"
      when "release"        then "release"
      else                       type
      end
    end

    private def colorize?(io : IO) : Bool
      io.responds_to?(:tty?) && io.tty?
    end

    private def green(text : String, io : IO) : String
      colorize?(io) ? text.colorize.green.to_s : text
    end

    private def red(text : String, io : IO) : String
      colorize?(io) ? text.colorize.red.to_s : text
    end

    private def yellow(text : String, io : IO) : String
      colorize?(io) ? text.colorize.yellow.to_s : text
    end

    private def dim(text : String, io : IO) : String
      colorize?(io) ? text.colorize.dim.to_s : text
    end
  end
end
