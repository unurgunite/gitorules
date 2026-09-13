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

      # True when branch work must be skipped for an `only` filter.
      #
      # Branch work runs when no filter is set or when the filter
      # names `branch`. Valid values are `branch`, `labels`, `workflows`.
      private def branch_skipped?(only : String?) : Bool
        parts = only_parts(only)
        return false if parts.nil?
        !parts.includes?("branch")
      end

      # True when label work must be skipped for an `only` filter.
      private def labels_skipped?(only : String?) : Bool
        parts = only_parts(only)
        return false if parts.nil?
        !parts.includes?("labels")
      end

      # True when label sync is configured and wanted for an `only` filter.
      private def labels_wanted?(only : String?) : Bool
        labels_configured? && !labels_skipped?(only)
      end

      private def only_parts(only : String?) : Set(String)?
        return if only.nil?
        cleaned = only.strip
        return if cleaned.empty?
        cleaned.split(",").map(&.strip.downcase).reject(&.empty?).to_set
      end

      # Builds the label synchronizer for the current config.
      private def label_resource : LabelResource
        LabelResource.new(@client, @config)
      end

      # True when the config declares any labels to sync.
      private def labels_configured? : Bool
        if labels = @config.labels
          !labels.empty?
        else
          false
        end
      end

      def status(repos : Array(String), quiet : Bool = false, io : IO = STDOUT, only : String? = nil)
        types = @config.all_type_keys
        status_print_header(types, io) unless quiet || branch_skipped?(only)
        total = repos.size
        is_tty = colorize?(io)
        outputs = Concurrent.map_ordered(repos) do |repo, idx|
          prefix = "[#{idx + 1}/#{total}] "
          buf = TtyMemory.new(is_tty)
          failed = false
          begin
            status_repo(buf, repo, types, prefix, quiet, only)
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
          io.puts status_summary_line(only, n)
        else
          io.puts "Done: #{n} repos processed, #{errors} error(s)"
        end
      end

      # Summary line for status that reflects the active `only` filter.
      #
      # Labels-only runs report labels, workflows-only runs report
      # workflows, and branch runs report branch rules. This keeps the
      # summary accurate when a subsystem filter is active.
      private def status_summary_line(only : String?, repo_count : Int32) : String
        parts = only_parts(only)
        return "All branch rules up to date" if parts.nil?

        has_branch = parts.includes?("branch")
        has_labels = parts.includes?("labels")
        has_workflows = parts.includes?("workflows")

        if has_branch && has_labels
          "All branch rules and labels up to date"
        elsif has_branch && has_workflows
          "All branch rules and workflows up to date"
        elsif has_branch
          "All branch rules up to date"
        elsif has_labels && has_workflows
          "All labels and workflows up to date"
        elsif has_labels
          "All labels up to date"
        elsif has_workflows
          "All workflows up to date"
        else
          "Done: #{repo_count} repos processed"
        end
      end

      private def status_repo(io : IO, repo : String, types : Array(String), prefix : String, quiet : Bool, only : String?)
        status_repo_line(repo, types, io, prefix, quiet) unless branch_skipped?(only)
        return unless labels_wanted?(only)
        begin
          label_resource.status(repo, quiet, io, prefix)
        rescue ex
          io.puts "#{prefix}#{repo}: labels Error: #{ex.message}" unless quiet
        end
      end

      def status_json(repos : Array(String), io : IO = STDOUT, only : String? = nil)
        types = @config.all_type_keys
        results = Concurrent.map_ordered(repos) do |repo, _idx|
          status_repo_json_string(repo, types, only)
        end
        io.puts("[#{results.join(",")}]")
      end

      private def status_repo_json_string(repo : String, types : Array(String), only : String? = nil) : String
        JSON.build do |json|
          json.object do
            json.field "repo", repo
            status_json_repo(json, repo, types, only)
          end
        end
      end

      # True when workflow work must be skipped for an `only` filter.
      private def workflows_skipped?(only : String?) : Bool
        parts = only_parts(only)
        return false if parts.nil?
        !parts.includes?("workflows")
      end

      # True when workflow sync is wanted for an `only` filter.
      private def workflows_wanted?(only : String?) : Bool
        !workflows_skipped?(only)
      end

      def diff(repos : Array(String), quiet : Bool = false, io : IO = STDOUT, only : String? = nil, verbose : Bool = false)
        validate_workflows!(repos)
        total = repos.size
        is_tty = colorize?(io)
        outputs = Concurrent.map_ordered(repos) do |repo, idx|
          prefix = "[#{idx + 1}/#{total}] "
          buf = TtyMemory.new(is_tty)
          begin
            diff_repo(repo, buf, prefix, quiet, only, verbose)
          rescue ex
            buf.puts "#{prefix}#{repo}: Error: #{ex.message}" unless quiet
          end
          buf.to_s
        end
        outputs.each { |text| io.print(text) }
        io.puts "Done: #{repos.size} repos processed"
      end

      # Validates workflow config for all repos before any API write.
      #
      # Raises `WorkflowError` (CLI maps it to exit 2) when a target
      # path falls outside the `.github/workflows/*.yml` allowlist.
      private def validate_workflows!(repos : Array(String))
        WorkflowResource.new(@client).validate_all!(@config, repos)
      end

      def diff_json(repos : Array(String), io : IO = STDOUT, only : String? = nil)
        validate_workflows!(repos)
        results = Concurrent.map_ordered(repos) do |repo, _idx|
          diff_repo_json_string(repo, only)
        end
        io.puts("[#{results.join(",")}]")
      end

      private def diff_repo_json_string(repo : String, only : String? = nil) : String
        JSON.build do |json|
          write_repo_json_entry(json, repo, only)
        end
      end

      private def write_repo_json_entry(json : JSON::Builder, repo : String, only : String? = nil)
        diff_json_repo(json, repo, only)
      rescue ex
        json.object do
          json.field "repo", repo
          json.field "resource", ""
          json.field "action", "error"
          json.field "changes", [] of String
          json.field "error", ex.message
        end
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

      def apply(repos : Array(String), dry_run : Bool = false, quiet : Bool = false, io : IO = STDOUT, only : String? = nil, verbose : Bool = false)
        validate_workflows!(repos)
        total = repos.size
        is_tty = colorize?(io)
        outputs = Concurrent.map_ordered(repos) do |repo, idx|
          prefix = "[#{idx + 1}/#{total}] "
          buf = TtyMemory.new(is_tty)
          failed = false
          begin
            apply_repo(repo, dry_run, buf, prefix, quiet, only, verbose)
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

      def apply_json(repos : Array(String), dry_run : Bool = false, io : IO = STDOUT, only : String? = nil)
        validate_workflows!(repos)
        results = Concurrent.map_ordered(repos) do |repo, _idx|
          apply_repo_json_string(repo, dry_run, only)
        end
        io.puts("[#{results.join(",")}]")
      end

      private def apply_repo_json_string(repo : String, dry_run : Bool, only : String? = nil) : String
        JSON.build do |json|
          write_apply_json_entry(json, repo, dry_run, only)
        end
      end

      private def write_apply_json_entry(json : JSON::Builder, repo : String, dry_run : Bool, only : String? = nil)
        apply_json_repo(json, repo, dry_run, only)
      rescue ex
        json.object do
          json.field "repo", repo
          json.field "resource", ""
          json.field "action", "error"
          json.field "changes", [] of String
          json.field "error", ex.message
        end
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

      private def status_json_repo(json : JSON::Builder, repo : String, types : Array(String), only : String? = nil)
        unless branch_skipped?(only)
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
        end
        if labels_wanted?(only)
          entries = label_resource.diff_entries(repo)
          json.field "labels" do
            json.array do
              entries.each { |e| label_resource.write_json_entry(json, repo, e) }
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

      private def rules_missing_for_repo?(repo : String) : Bool
        @config.rules_for(repo).nil?
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

      private def diff_repo(repo : String, io : IO, prefix : String = "", quiet : Bool = false, only : String? = nil, verbose : Bool = false)
        diff_repo_rulesets(repo, io, prefix, quiet) unless branch_skipped?(only)
        diff_repo_labels(repo, io, prefix, quiet) if labels_wanted?(only)
        diff_repo_workflows(repo, io, quiet, verbose) if workflows_wanted?(only)
      end

      private def diff_repo_rulesets(repo : String, io : IO, prefix : String, quiet : Bool)
        existing = fetch_rulesets_or_report(repo, io, prefix, quiet)
        return unless existing

        io.puts "#{prefix}=== #{repo} ===" unless quiet

        entries = compare(repo, existing, @config.rules_for(repo))
        entries.each do |entry|
          render_text_entry(entry, io, quiet)
        end

        io.puts "" unless quiet
      end

      private def fetch_rulesets_or_report(repo : String, io : IO, prefix : String, quiet : Bool) : Array(Ruleset)?
        @client.list_rulesets(repo)
      rescue ex
        io.puts "#{prefix}#{repo}: Error: #{ex.message}" unless quiet
        nil
      end

      private def diff_repo_labels(repo : String, io : IO, prefix : String, quiet : Bool)
        label_resource.diff(repo, quiet, io, prefix)
      rescue ex
        io.puts "#{prefix}#{repo}: labels Error: #{ex.message}" unless quiet
      end

      # Prints pending workflow changes for a repo (no writes).
      private def diff_repo_workflows(repo : String, io : IO, quiet : Bool, verbose : Bool)
        workflows = @config.workflows_for(repo)
        return if workflows.nil? || workflows.empty?
        plans = WorkflowResource.new(@client).plan_repo(repo, workflows)
        plans.each do |plan|
          case plan.action
          when "create"
            io.puts "  #{diff_add("Create workflow '#{plan.target}'", io)}" unless quiet
          when "update"
            io.puts "  #{diff_change("Update workflow '#{plan.target}'", io)}" unless quiet
          when "unchanged"
            io.puts "  #{diff_unchanged("workflow '#{plan.target}' up to date", io)}" if verbose && !quiet
          end
        end
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

      private def diff_json_repo(json : JSON::Builder, repo : String, only : String? = nil)
        existing = fetch_diff_rulesets(json, repo, only)
        return unless existing
        label_entries = fetch_diff_labels(json, repo, only)
        return unless label_entries

        json.object do
          json.field "repo", repo
          json.field "changes" do
            json.array do
              render_diff_branch_entries(json, repo, existing, only) unless branch_skipped?(only)
              label_entries.each { |e| label_resource.write_json_entry(json, repo, e) }
              render_diff_workflow_entries(json, repo, only) if workflows_wanted?(only)
            end
          end
        end
      end

      private def fetch_diff_rulesets(json : JSON::Builder, repo : String, only : String?) : Array(Ruleset)?
        return [] of Ruleset if branch_skipped?(only)
        @client.list_rulesets(repo)
      rescue ex
        write_repo_error_entry(json, repo, ex.message)
        nil
      end

      private def fetch_diff_labels(json : JSON::Builder, repo : String, only : String?) : Array(LabelChange)?
        return [] of LabelChange unless labels_wanted?(only)
        label_resource.diff_entries(repo)
      rescue ex
        write_repo_error_entry(json, repo, ex.message)
        nil
      end

      private def write_repo_error_entry(json : JSON::Builder, repo : String, message : String?)
        json.object do
          json.field "repo", repo
          json.field "resource", ""
          json.field "action", "error"
          json.field "changes", [] of String
          json.field "error", message
        end
      end

      private def render_diff_branch_entries(json : JSON::Builder, repo : String, existing : Array(Ruleset), only : String?)
        unless @config.rules_for(repo)
          render_json_skip(json)
          return
        end
        entries = compare(repo, existing, @config.rules_for(repo))
        entries.each do |entry|
          render_diff_branch_entry(json, entry)
        end
      end

      private def render_diff_branch_entry(json : JSON::Builder, entry : DiffEntry)
        case entry.kind
        when .create?
          if wanted = entry.wanted
            render_json_create(json, wanted)
          end
        when .update?, .unchanged?
          render_diff_update_entry(json, entry)
        when .orphan?
          render_json_orphan(json, entry.name)
        end
      end

      private def render_diff_update_entry(json : JSON::Builder, entry : DiffEntry)
        if entry.fetch_error
          if wanted = entry.wanted
            render_json_create(json, wanted)
          end
        else
          render_json_update(json, entry)
        end
      end

      # Appends workflow plans to a diff JSON changes array.
      #
      # Report-only: plans are computed via GETs, no PUTs are performed.
      private def render_diff_workflow_entries(json : JSON::Builder, repo : String, only : String?)
        workflows = @config.workflows_for(repo)
        return if workflows.nil? || workflows.empty?
        plans = WorkflowResource.new(@client).plan_repo(repo, workflows)
        plans.each do |plan|
          write_workflow_json_entry(json, plan)
        end
      rescue ex
        json.object do
          json.field "resource", ""
          json.field "action", "error"
          json.field "changes", [] of String
          json.field "error", ex.message
        end
      end

      private def write_workflow_json_entry(json : JSON::Builder, plan : WorkflowPlan, dry_run : Bool = false)
        json.object do
          json.field "resource", plan.target
          json.field "action", plan.action
          json.field "name", plan.target
          json.field "changes", [] of String
          json.field "dry_run", true if dry_run
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
          json.field "resource", wanted.name
          json.field "rules", wanted.rules.map(&.type)
          if conditions = wanted.conditions
            if ref = conditions["ref_name"]?
              if inc = ref.as_h["include"]?.try(&.as_a)
                json.field "branches", inc.map(&.to_s)
              end
            end
          end
          json.field "changes", [] of String
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
          json.field "resource", entry.name
          json.field "changes", changes
        end
      end

      private def render_json_orphan(json : JSON::Builder, name : String)
        json.object do
          json.field "action", "orphan"
          json.field "name", name
          json.field "resource", name
          json.field "changes", [] of String
        end
      end

      private def render_json_skip(json : JSON::Builder)
        json.object do
          json.field "action", "skip"
          json.field "resource", ""
          json.field "changes", [] of String
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

      private def apply_json_repo(json : JSON::Builder, repo : String, dry_run : Bool, only : String? = nil)
        existing = [] of Ruleset
        unless branch_skipped?(only)
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
        end

        label_entries = [] of LabelChange
        if labels_wanted?(only)
          begin
            label_entries = label_resource.apply_preview(repo)
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
        end

        json.object do
          json.field "repo", repo
          json.field "results" do
            json.array do
              unless branch_skipped?(only)
                unless @config.rules_for(repo)
                  render_json_skip(json)
                  next
                end
                if repo_rules = @config.rules_for(repo)
                  repo_rules.each do |type, config|
                    wanted = build_type_ruleset(type, config)
                    names = type_match_names(type, config)
                    found = existing.find(&.name.in?(names))
                    apply_json_ruleset(json, repo, found, wanted, config, dry_run)
                  end
                end
              end
              label_entries.each { |e| label_resource.write_json_entry(json, repo, e, dry_run) }
              render_apply_workflow_entries(json, repo, only, dry_run) if workflows_wanted?(only)
            end
          end
        end
      end

      # Appends workflow plans to an apply JSON results array.
      #
      # Report-only: plans are computed via GETs, no PUTs are performed
      # (consistent with ruleset JSON handling).
      private def render_apply_workflow_entries(json : JSON::Builder, repo : String, only : String?, dry_run : Bool)
        workflows = @config.workflows_for(repo)
        return if workflows.nil? || workflows.empty?
        plans = WorkflowResource.new(@client).plan_repo(repo, workflows)
        plans.each do |plan|
          write_workflow_json_entry(json, plan, dry_run)
        end
      rescue ex
        json.object do
          json.field "resource", ""
          json.field "action", "error"
          json.field "changes", [] of String
          json.field "error", ex.message
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

      private def apply_repo(repo : String, dry_run : Bool, io : IO, prefix : String = "", quiet : Bool = false, only : String? = nil, verbose : Bool = false)
        unless branch_skipped?(only)
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

        if labels_wanted?(only)
          label_resource.apply(repo, dry_run, quiet, io, prefix)
        end

        if workflows_wanted?(only)
          apply_workflows(repo, dry_run, io, prefix, quiet, verbose)
        end
      end

      # Syncs workflows for a repo via the Contents API.
      #
      # Dry-run mode performs zero PUTs and prints intentions instead.
      # Matching shas are skipped silently unless verbose.
      private def apply_workflows(repo : String, dry_run : Bool, io : IO, prefix : String = "", quiet : Bool = false, verbose : Bool = false)
        workflows = @config.workflows_for(repo)
        return if workflows.nil? || workflows.empty?
        plans = WorkflowResource.new(@client).sync_repo(repo, workflows, dry_run)
        plans.each do |plan|
          report_workflow_plan(repo, plan, dry_run, io, prefix, quiet, verbose)
        end
      end

      private def report_workflow_plan(repo : String, plan : WorkflowPlan, dry_run : Bool, io : IO, prefix : String, quiet : Bool, verbose : Bool)
        case plan.action
        when "create"
          report_workflow_write(repo, plan.target, "create", "Created", dry_run, io, prefix, quiet)
        when "update"
          report_workflow_write(repo, plan.target, "update", "Updated", dry_run, io, prefix, quiet)
        when "unchanged"
          io.puts "#{prefix}#{repo}: Workflow '#{plan.target}' up to date" if verbose && !quiet
        end
      end

      private def report_workflow_write(repo : String, target : String, present : String, past : String, dry_run : Bool, io : IO, prefix : String, quiet : Bool)
        if dry_run
          io.puts "#{prefix}#{repo}: Would #{present} workflow '#{target}'" unless quiet
        else
          io.puts "#{prefix}#{repo}: #{past} workflow '#{target}'" unless quiet
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
