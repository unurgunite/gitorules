require "../resource"

module Gitorules
  module Resources
    # Branch rulesets resource.
    #
    # Owns branch ruleset comparison, rendering and apply logic.
    # Engine delegates to this resource and keeps CLI output stable.
    class BranchRules < Resource
      @client : GitHubClient
      @config : Config

      # Single comparison result shared by text and JSON renderers.
      struct DiffEntry
        enum Kind
          Create
          Update
          Unchanged
          Orphan
        end

        property kind : Kind
        property name : String
        property wanted : Ruleset?
        property added : Array(String)
        property removed : Array(String)
        property param_changes : Array(String)
        property? glob_matched : Bool
        property fetch_error : String?

        def initialize(
          @kind : Kind,
          @name : String,
          @wanted : Ruleset? = nil,
          @added : Array(String) = [] of String,
          @removed : Array(String) = [] of String,
          @param_changes : Array(String) = [] of String,
          @glob_matched : Bool = false,
          @fetch_error : String? = nil,
        )
        end

        def self.create(wanted : Ruleset) : DiffEntry
          new(Kind::Create, wanted.name, wanted: wanted)
        end

        def self.orphan(name : String) : DiffEntry
          new(Kind::Orphan, name)
        end

        def self.fetch_error(wanted : Ruleset, message : String?) : DiffEntry
          new(Kind::Update, wanted.name, wanted: wanted, fetch_error: message)
        end
      end

      def initialize(@client : GitHubClient, @config : Config)
      end

      def status(repos : Array(String), quiet : Bool = false, io : IO = STDOUT)
        types = @config.all_type_keys
        status_print_header(types, io) unless quiet
        errors = 0
        repos.each_with_index do |repo, i|
          prefix = "[#{i + 1}/#{repos.size}] "
          begin
            status_repo_line(repo, types, io, prefix, quiet)
          rescue
            io.puts error_io_line(repo, types, prefix, io) unless quiet
            errors += 1
          end
        end
        n = repos.size
        if errors == 0
          io.puts "All rulesets up to date"
        else
          io.puts "Done: #{n} repos processed, #{errors} error(s)"
        end
      end

      def status_json(repos : Array(String), io : IO = STDOUT)
        types = @config.all_type_keys
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

      def diff(repos : Array(String), quiet : Bool = false, io : IO = STDOUT)
        repos.each_with_index do |repo, i|
          prefix = "[#{i + 1}/#{repos.size}] "
          begin
            diff_repo(repo, io, prefix, quiet)
          rescue ex
            io.puts "#{prefix}#{repo}: Error: #{ex.message}" unless quiet
          end
        end
        io.puts "Done: #{repos.size} repos processed"
      end

      def diff_json(repos : Array(String), io : IO = STDOUT)
        errors = 0
        io.puts(JSON.build do |json|
          json.array do
            repos.each do |repo|
              errors += diff_json_repo_entry(json, repo)
            end
          end
        end)
      end

      private def diff_json_repo_entry(json : JSON::Builder, repo : String) : Int32
        diff_json_repo(json, repo)
        0
      rescue ex
        json.object do
          json.field "repo", repo
          json.field "error", ex.message
        end
        1
      end

      def apply(repos : Array(String), dry_run : Bool = false, quiet : Bool = false, io : IO = STDOUT)
        errors = 0
        repos.each_with_index do |repo, i|
          prefix = "[#{i + 1}/#{repos.size}] "
          begin
            apply_repo(repo, dry_run, io, prefix, quiet)
          rescue ex
            io.puts "#{prefix}#{repo}: Error: #{ex.message}" unless quiet
            errors += 1
          end
        end
        n = repos.size
        io.puts "Done: #{n} repos processed, #{errors} error(s)"
      end

      def apply_json(repos : Array(String), dry_run : Bool = false, io : IO = STDOUT)
        errors = 0
        io.puts(JSON.build do |json|
          json.array do
            repos.each do |repo|
              errors += apply_json_repo_entry(json, repo, dry_run)
            end
          end
        end)
      end

      private def apply_json_repo_entry(json : JSON::Builder, repo : String, dry_run : Bool) : Int32
        apply_json_repo(json, repo, dry_run)
        0
      rescue ex
        json.object do
          json.field "repo", repo
          json.field "error", ex.message
        end
        1
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
            checks_ok = if rule_config.try(&.glob_checks?)
                          actual_str = actual.try(&.compact) || [] of String
                          rule_config.try(&.checks_match?(actual_str)) || false
                        else
                          actual == expected_checks
                        end
            json.field "checks_ok", checks_ok
          end
        end
      end

      # Single comparison core shared by text and JSON diff renderers.
      private def compare(repo : String, existing : Array(Ruleset), repo_rules : Hash(String, BranchRuleConfig)?) : Array(DiffEntry)
        entries = [] of DiffEntry
        matched = Set(String).new

        if repo_rules
          repo_rules.each do |type, config|
            wanted = build_type_ruleset(type, config)
            names = type_match_names(type, config)
            found = existing.find(&.name.in?(names))
            matched << found.name if found

            unless found
              entries << DiffEntry.create(wanted)
              next
            end

            id = found.id
            unless id
              entries << DiffEntry.create(wanted)
              next
            end

            begin
              full = @client.get_ruleset(repo, id)
            rescue ex
              entries << DiffEntry.fetch_error(wanted, ex.message)
              next
            end

            entries << compare_rulesets(wanted, full, config)
          end
        end

        existing.each do |rs|
          next if rs.name.in?(matched)
          entries << DiffEntry.orphan(rs.name)
        end

        entries
      end

      # Compares a wanted ruleset against the full existing ruleset.
      private def compare_rulesets(wanted : Ruleset, full : Ruleset, config : BranchRuleConfig) : DiffEntry
        existing_types = Set.new(full.rules.map(&.type))
        wanted_types = Set.new(wanted.rules.map(&.type))

        added = (wanted_types - existing_types).to_a
        removed = (existing_types - wanted_types).to_a
        if config.glob_checks?
          removed.delete("required_status_checks")
        end

        param_changes = [] of String
        wanted.rules.each do |wanted_rule|
          existing_rule = full.rules.find { |r| r.type == wanted_rule.type }
          next unless existing_rule

          wanted_params = wanted_rule.parameters
          existing_params = existing_rule.parameters
          next unless wanted_params && existing_params

          wanted_params.each do |key, wanted_val|
            existing_val = existing_params[key]?
            if existing_val != wanted_val
              param_changes << "#{key}: #{existing_val} → #{wanted_val}"
            end
          end
        end

        glob_matched = config.glob_checks? && full.rules.any? { |r| r.type == "required_status_checks" }
        name = wanted.name

        if added.empty? && removed.empty? && param_changes.empty? && !glob_matched
          DiffEntry.new(DiffEntry::Kind::Unchanged, name, wanted: wanted)
        else
          DiffEntry.new(
            DiffEntry::Kind::Update, name,
            wanted: wanted,
            added: added,
            removed: removed,
            param_changes: param_changes,
            glob_matched: glob_matched
          )
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

        entries = compare(repo, existing, @config.rules_for(repo))
        entries.each do |entry|
          render_text_entry(entry, io, quiet)
        end

        io.puts "" unless quiet
      end

      private def render_text_entry(entry : DiffEntry, io : IO, quiet : Bool = false)
        case entry.kind
        when .create?
          if wanted = entry.wanted
            render_text_create(wanted, io, quiet)
          end
        when .update?, .unchanged?
          render_text_update_entry(entry, io, quiet)
        when .orphan?
          io.puts "  #{diff_orphan(entry.name, io)}" unless quiet
        end
      end

      private def render_text_update_entry(entry : DiffEntry, io : IO, quiet : Bool = false)
        if message = entry.fetch_error
          if wanted = entry.wanted
            io.puts "  #{wanted.name}: Error fetching full ruleset: #{message}" unless quiet
          end
        else
          render_text_update(entry, io, quiet)
        end
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
              entries = compare(repo, existing, @config.rules_for(repo))
              entries.each do |entry|
                case entry.kind
                when .create?
                  if wanted = entry.wanted
                    render_json_create(json, wanted)
                  end
                when .update?, .unchanged?
                  if entry.fetch_error
                    if wanted = entry.wanted
                      render_json_create(json, wanted)
                    end
                  else
                    render_json_update(json, entry)
                  end
                when .orphan?
                  render_json_orphan(json, entry.name)
                end
              end
            end
          end
        end
      end

      private def render_text_create(wanted : Ruleset, io : IO, quiet : Bool = false)
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

      private def render_text_update(entry : DiffEntry, io : IO, quiet : Bool = false)
        changes = [] of String

        entry.added.each { |r| changes << diff_add(r, io) }
        entry.removed.each { |r| changes << diff_remove(r, io) }
        entry.param_changes.each { |c| changes << c }

        if entry.glob_matched?
          changes << diff_unchanged("required_status_checks (matched by glob pattern, left unchanged)", io)
        end

        if changes.empty?
          io.puts "  #{entry.name}: #{diff_unchanged("no changes", io)}" unless quiet
        else
          io.puts "  #{diff_change("Update ruleset '#{entry.name}'", io)}" unless quiet
          changes.each { |c| io.puts "    #{c}" } unless quiet
        end
      end

      private def render_json_create(json : JSON::Builder, wanted : Ruleset)
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

      private def render_json_update(json : JSON::Builder, entry : DiffEntry)
        changes = [] of String
        entry.added.each { |r| changes << "+#{r}" }
        entry.removed.each { |r| changes << "-#{r}" }
        changes.concat(entry.param_changes)
        if entry.glob_matched?
          changes << "required_status_checks (matched by glob pattern)"
        end

        json.object do
          json.field "action", changes.empty? ? "unchanged" : "update"
          json.field "name", entry.name
          unless changes.empty?
            json.field "changes", changes
          end
        end
      end

      private def render_json_orphan(json : JSON::Builder, name : String)
        json.object do
          json.field "action", "orphan"
          json.field "name", name
        end
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
              if repo_rules = @config.rules_for(repo)
                repo_rules.each do |type, config|
                  wanted = build_type_ruleset(type, config)
                  names = type_match_names(type, config)
                  found = existing.find(&.name.in?(names))
                  apply_json_ruleset(json, repo, found, wanted, config, dry_run)
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
            json.field "dry_run", true if dry_run
            json.field "id", existing.id if existing && existing.id
            json_apply_checks_skipped(json, action, config)
          end
          return
        end

        json.object do
          json.field "action", "update"
          json.field "name", wanted.name
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

      private def preserve_glob_checks(repo : String, id : Int64, wanted : Ruleset, config : BranchRuleConfig)
        return unless config.glob_checks?

        begin
          full = @client.get_ruleset(repo, id)
          if existing_checks = full.rules.find { |r| r.type == "required_status_checks" }
            wanted.rules << existing_checks unless wanted.rules.any? { |r| r.type == "required_status_checks" }
          end
        rescue
        end
      end

      private def apply_ruleset_create_message(repo : String, wanted : Ruleset, config : BranchRuleConfig, io : IO, prefix : String, quiet : Bool)
        if config.glob_checks?
          io.puts "#{prefix}#{repo}: Created ruleset '#{wanted.name}' (checks skipped — glob patterns can't be applied on create)" unless quiet
        else
          io.puts "#{prefix}#{repo}: Created ruleset '#{wanted.name}'" unless quiet
        end
      end

      private def type_label(type : String) : String
        case type
        when "default_branch" then "default"
        when "release"        then "release"
        else                       type
        end
      end
    end
  end
end
