require "yaml"

module Gitorules
  # Result of validating a config file.
  #
  # Errors fail the lint (exit 2). Warnings print to STDERR
  # but keep exit code 0.
  struct LintResult
    property errors : Array(String)
    property warnings : Array(String)

    def initialize(@errors : Array(String) = [] of String, @warnings : Array(String) = [] of String)
    end

    def clean? : Bool
      errors.empty?
    end
  end

  # Offline schema validator for `.gitorules.yml`.
  #
  # Checks rule values without calling the GitHub API. Every error
  # states what is wrong, where (file and key), and how to fix it.
  class Linter
    CHECK_RUNS_CMD    = "gh api repos/<org>/<repo>/commits/HEAD/check-runs --jq '.check_runs[].name'"
    VALID_RULE_FIELDS = %w[merge squash rebase name pattern checks linear_history delete_branch]
    VALID_TOP_LEVEL   = %w[org repos rules orgs defaults scopes labels labels_sync workflows files]

    # Lints a config file. Prints errors and warnings.
    #
    # Returns 2 when errors are found, 0 otherwise. Warnings
    # do not affect the exit code.
    def self.lint_file(path : String, io : IO = STDOUT, err : IO = STDERR) : Int32
      content = File.read(path)
    rescue File::NotFoundError
      err.puts "Error in #{path}: file not found. Fix: create the file or pass --config PATH to an existing config."
      2
    rescue ex
      err.puts "Error in #{path}: cannot read file (#{ex.message}). Fix: check the path and file permissions."
      2
    else
      result = lint_content(content, path)
      result.warnings.each { |w| err.puts "Warning: #{w}" }
      if result.clean?
        io.puts "OK: #{path} is valid"
        0
      else
        result.errors.each { |e| err.puts "Error: #{e}" }
        2
      end
    end

    # Validates YAML content and returns errors and warnings.
    #
    # The *path* argument is only used in messages so errors
    # point at the offending file and key.
    def self.lint_content(content : String, path : String = ".gitorules.yml") : LintResult
      errors = [] of String
      warnings = [] of String

      root = YAML.parse(content)
      unless hash = root.as_h?
        errors << "in #{path} at <root>: the config must be a YAML mapping. Fix: start the file with a key such as `rules:` or `scopes:`."
        return LintResult.new(errors, warnings)
      end

      keys = hash.keys.compact_map(&.as_s?)
      unknown = keys - VALID_TOP_LEVEL
      unknown.each do |key|
        errors << "in #{path} at #{key}: unknown top-level key `#{key}`. Fix: use one of #{VALID_TOP_LEVEL.join(", ")} or remove the key."
      end

      str_map = {} of String => YAML::Any
      hash.each do |k, v|
        if name = k.as_s?
          str_map[name] = v
        end
      end

      if rules = str_map["rules"]?
        lint_rules_map(rules, "rules", path, str_map["org"]?.try(&.as_s?), errors, warnings)
      end

      if orgs = str_map["orgs"]?
        lint_orgs(orgs, path, errors, warnings)
      end

      if defaults = str_map["defaults"]?
        lint_defaults(defaults, path, errors, warnings)
      end

      if scopes = str_map["scopes"]?
        lint_scopes(scopes, path, errors, warnings)
      end

      if workflows = str_map["workflows"]?
        lint_workflows(workflows, "workflows", path, errors)
      end

      lint_top_level_types(str_map, path, errors)
      lint_has_any_rules(str_map, path, errors)
      lint_consistency(content, path, errors, warnings)

      LintResult.new(errors, warnings)
    rescue ex : YAML::ParseException
      errors = ["in #{path}: the file is not valid YAML (#{ex.message}). Fix: check indentation and quoting, then retry."]
      LintResult.new(errors, [] of String)
    end

    private def self.lint_top_level_types(str_map : Hash(String, YAML::Any), path : String, errors : Array(String)) : Nil
      if org = str_map["org"]?
        unless org.as_s?
          errors << "in #{path} at org: the organization name must be a string. Fix: use `org: myorg`."
        end
      end
      if repos = str_map["repos"]?
        if list = repos.as_a?
          list.each_with_index do |entry, i|
            unless entry.as_s?
              errors << "in #{path} at repos[#{i}]: every entry must be a string. Fix: quote the name, e.g. `\"myrepo\"`."
            end
          end
        else
          errors << "in #{path} at repos: the repository list must be an array. Fix: use a list such as `repos:\\n  - myrepo`."
        end
      end
    end

    private def self.lint_has_any_rules(str_map : Hash(String, YAML::Any), path : String, errors : Array(String)) : Nil
      return if str_map["rules"]? || str_map["orgs"]? || str_map["defaults"]? || str_map["scopes"]? || str_map["workflows"]? || str_map["files"]? || str_map["labels"]?
      errors << "in #{path}: no rules found. Fix: add a `rules:` section, an `orgs:` section, or a `defaults:`/`scopes:` pair."
    end

    # Cross-checks required checks against synced workflow templates.
    #
    # Every exact check must be produced by a job in the scope
    # workflows. Missing checks become errors, extra jobs become
    # warnings. Scopes without workflows are skipped.
    private def self.lint_consistency(content : String, path : String, errors : Array(String), warnings : Array(String)) : Nil
      config = Config.from_yaml(content)
      base_dir = begin
        File.dirname(File.expand_path(path))
      rescue
        Dir.current
      end
      _, consistency_errors, consistency_warnings = Consistency.check_all(config, base_dir, path)
      errors.concat(consistency_errors)
      warnings.concat(consistency_warnings)
    rescue
      # Config parsing failed; schema errors already reported.
    end

    private def self.lint_orgs(orgs : YAML::Any, path : String, errors : Array(String), warnings : Array(String)) : Nil
      org_hash = orgs.as_h?
      unless org_hash
        errors << "in #{path} at orgs: expected a mapping of organization names. Fix: use `orgs:\\n  myorg:\\n    repos: [...]`."
        return
      end
      org_hash.each do |org_key, org_val|
        org_name = org_key.as_s? || "?"
        org_map = org_val.as_h?
        unless org_map
          errors << "in #{path} at orgs.#{org_name}: expected a mapping with `repos` and `rules`. Fix: indent `repos:` and `rules:` under the org name."
          next
        end
        org_map.each do |k, v|
          name = k.as_s?
          case name
          when "rules"
            lint_rules_map(v, "orgs.#{org_name}.rules", path, org_name, errors, warnings)
          when "workflows"
            lint_workflows(v, "orgs.#{org_name}.workflows", path, errors)
          end
        end
      end
    end

    private def self.lint_defaults(defaults : YAML::Any, path : String, errors : Array(String), warnings : Array(String)) : Nil
      defaults_map = defaults.as_h?
      unless defaults_map
        errors << "in #{path} at defaults: expected a mapping. Fix: use `defaults:\\n  rules:\\n    default_branch:\\n      merge: only`."
        return
      end
      defaults_map.each do |k, v|
        name = k.as_s?
        next unless name == "rules"
        lint_rules_map(v, "defaults.rules", path, nil, errors, warnings)
      end
    end

    private def self.lint_scopes(scopes : YAML::Any, path : String, errors : Array(String), warnings : Array(String)) : Nil
      scopes_map = scopes.as_h?
      unless scopes_map
        errors << "in #{path} at scopes: expected a mapping of scope names. Fix: use `scopes:\\n  backend:\\n    repos: [org/repo]`."
        return
      end
      if scopes_map.empty?
        errors << "in #{path} at scopes: at least one scope is required. Fix: add a named scope with a `repos:` list."
      end
      scopes_map.each do |scope_key, scope_val|
        scope_name = scope_key.as_s? || "?"
        scope_map = scope_val.as_h?
        unless scope_map
          errors << "in #{path} at scopes.#{scope_name}: expected a mapping with `repos` and optional `rules`. Fix: indent `repos:` under the scope name."
          next
        end
        scope_map.each do |k, v|
          field = k.as_s?
          case field
          when "rules"
            lint_rules_map(v, "scopes.#{scope_name}.rules", path, nil, errors, warnings)
          when "repos"
            unless v.as_a?
              errors << "in #{path} at scopes.#{scope_name}.repos: expected a list of repositories. Fix: use `repos:\\n      - org/repo`."
            end
          when "exclude", "labels", "workflows", "files"
            # Reserved fields, no validation needed.
          else
            if field
              errors << "in #{path} at scopes.#{scope_name}.#{field}: unknown scope field `#{field}`. Fix: use `repos`, `exclude`, or `rules`, or remove the key."
            end
          end
        end
      end
    end

    private def self.lint_workflows(node : YAML::Any, prefix : String, path : String, errors : Array(String)) : Nil
      workflows_hash = node.as_h?
      unless workflows_hash
        errors << "in #{path} at #{prefix}: expected a mapping of workflow files. Fix: use `#{prefix}:\\n  ci.yml:\\n    source: templates/ci.yml`."
        return
      end
      workflows_hash.each do |key, value|
        target_key = key.as_s? || "?"
        target = WorkflowResource.target_path(target_key)
        unless WorkflowResource.valid_target?(target)
          errors << "in #{path} at #{prefix}.#{target_key}: invalid workflow target '#{target_key}'. Fix: use only `.github/workflows/*.yml` file names with no subdirectories."
          next
        end
        entry_map = value.as_h?
        unless entry_map
          errors << "in #{path} at #{prefix}.#{target_key}: expected a mapping with `source`. Fix: use `#{target_key}:\\n    source: templates/#{target_key}`."
          next
        end
        source_node = entry_map[YAML::Any.new("source")]?
        text = source_node.try(&.as_s?)
        if text.nil? || text.strip.empty?
          errors << "in #{path} at #{prefix}.#{target_key}.source: a template source is required. Fix: set `source: templates/#{target_key}` or `source: owner/repo@v1:path/to/file.yml`."
          next
        end
        begin
          TemplateSource.parse(text)
        rescue ex : WorkflowError
          errors << "in #{path} at #{prefix}.#{target_key}.source: #{ex.message}. Fix: use a local path or `owner/repo@ref:path`."
        end
      end
    end

    private def self.lint_rules_map(node : YAML::Any, prefix : String, path : String, org : String?, errors : Array(String), warnings : Array(String)) : Nil
      rules_hash = node.as_h?
      unless rules_hash
        errors << "in #{path} at #{prefix}: expected a mapping of branch types. Fix: use `#{prefix}:\\n  default_branch:\\n    merge: only`."
        return
      end
      if rules_hash.empty?
        errors << "in #{path} at #{prefix}: at least one branch type is required. Fix: add e.g. `default_branch:` with `merge: only`."
      end
      rules_hash.each do |type_key, rule_val|
        type_name = type_key.as_s? || "?"
        lint_branch_rule(rule_val, "#{prefix}.#{type_name}", path, org, errors, warnings)
      end
    end

    # Validates one branch type entry.
    #
    # A merge method set to boolean `true` is an error: only the
    # string `"only"` is accepted. Unknown check names and glob
    # patterns produce warnings, never errors.
    private def self.lint_branch_rule(node : YAML::Any, location : String, path : String, org : String?, errors : Array(String), warnings : Array(String)) : Nil
      rule_map = node.as_h?
      unless rule_map
        errors << "in #{path} at #{location}: expected a mapping of rule fields. Fix: indent fields such as `merge: only` under the branch type."
        return
      end

      fields = {} of String => YAML::Any
      rule_map.each do |k, v|
        if name = k.as_s?
          fields[name] = v
        end
      end

      (fields.keys - VALID_RULE_FIELDS).each do |field|
        errors << "in #{path} at #{location}.#{field}: unknown field `#{field}`. Fix: use one of #{VALID_RULE_FIELDS.join(", ")} or remove the line."
      end

      lint_merge_methods(fields, location, path, errors)
      lint_rule_strings(fields, location, path, errors)

      if checks = fields["checks"]?
        lint_checks(checks, location, path, org, errors, warnings)
      end

      lint_pending_fields(fields, location, path, warnings)
    end

    private def self.lint_merge_methods(fields : Hash(String, YAML::Any), location : String, path : String, errors : Array(String)) : Nil
      %w[merge squash rebase].each do |method|
        next unless fields.has_key?(method)
        value = fields[method]
        if str = value.as_s?
          unless str == "only"
            errors << "in #{path} at #{location}.#{method}: found #{str.inspect}, but merge methods must be the string `\"only\"`. Fix: use `#{method}: only` to allow only #{method_label(method)}, or remove the line to allow all methods."
          end
        elsif !value.raw.nil?
          found = value.raw.inspect
          errors << "in #{path} at #{location}.#{method}: found #{found}, but merge methods must be the string `\"only\"`. Fix: use `#{method}: only` to allow only #{method_label(method)}, or remove the line to allow all methods."
        end
      end

      only = %w[merge squash rebase].select { |m| fields[m]?.try(&.as_s?) == "only" }
      if only.size > 1
        errors << "in #{path} at #{location}: conflicting merge methods (#{only.map { |m| "#{m}: only" }.join(" + ")}). Fix: keep only one merge method set to `only`, or remove all three to allow every method."
      end
    end

    private def self.lint_rule_strings(fields : Hash(String, YAML::Any), location : String, path : String, errors : Array(String)) : Nil
      if pattern = fields["pattern"]?
        unless pattern.as_s?
          errors << "in #{path} at #{location}.pattern: the branch pattern must be a string. Fix: quote it, e.g. `pattern: \"v*\"`."
        end
      end

      if name = fields["name"]?
        unless name.as_s?
          errors << "in #{path} at #{location}.name: the display name must be a string. Fix: quote it, e.g. `name: \"Main branch\"`."
        end
      end
    end

    private def self.lint_pending_fields(fields : Hash(String, YAML::Any), location : String, path : String, warnings : Array(String)) : Nil
      if fields["linear_history"]?.try(&.as_bool?) == true
        warnings << "in #{path} at #{location}.linear_history: this field is not enforced yet and will be ignored. Fix: remove the line or keep it as documentation."
      end

      if fields["delete_branch"]?.try(&.as_bool?) == true
        warnings << "in #{path} at #{location}.delete_branch: this field is not enforced yet and will be ignored. Fix: remove the line or keep it as documentation."
      end
    end

    private def self.lint_checks(node : YAML::Any, location : String, path : String, org : String?, errors : Array(String), warnings : Array(String)) : Nil
      list = node.as_a?
      unless list
        errors << "in #{path} at #{location}.checks: expected a list of check names. Fix: use e.g. `checks:\\n      - \"CI / build\"`."
        return
      end
      if list.empty?
        errors << "in #{path} at #{location}.checks: the list must not be empty. Fix: add at least one check name or remove the `checks:` line."
      end
      list.each_with_index do |entry, i|
        text = entry.as_s?
        unless text
          errors << "in #{path} at #{location}.checks[#{i}]: every check name must be a string. Fix: quote the name, e.g. `\"CI / build\"`."
          next
        end
        if text.strip.empty?
          errors << "in #{path} at #{location}.checks[#{i}]: check names must not be blank. Fix: remove the entry or use a real check name."
          next
        end
        if glob_check?(text)
          warnings << "in #{path} at #{location}.checks[#{i}] (#{text.inspect}): glob patterns are matched locally and are skipped when creating branch rules. Fix: keep the pattern for matching, or replace it with exact names from #{CHECK_RUNS_CMD}."
          next
        end
        unless text.includes?("/")
          hint = org ? " For this config, replace <org> with `#{org}` and <repo> with one of its repositories." : ""
          warnings << "in #{path} at #{location}.checks[#{i}] (#{text.inspect}): this does not look like a GitHub check name (expected \"Workflow / job\"). Fix: verify the name with #{CHECK_RUNS_CMD}.#{hint}"
        end
      end
    end

    private def self.method_label(method : String) : String
      case method
      when "merge"  then "merge commits"
      when "squash" then "squash merges"
      when "rebase" then "rebase merges"
      else               "#{method} merges"
      end
    end

    def self.glob_check?(text : String) : Bool
      text.includes?('*') || text.includes?('?') || text.includes?('[')
    end
  end

  # Converts a legacy `org`/`repos`/`rules` (or `orgs`) config
  # into the `defaults`/`scopes` shape.
  #
  # Prints to STDOUT by default and only overwrites the source
  # file when *in_place* is true.
  class Migrator
    # Migrates the file at *path*.
    #
    # Returns 0 on success, 2 on read, parse, or schema errors.
    def self.migrate_file(path : String, in_place : Bool = false, io : IO = STDOUT, err : IO = STDERR) : Int32
      content = File.read(path)
    rescue File::NotFoundError
      err.puts "Error in #{path}: file not found. Fix: create the file or pass --config PATH to an existing config."
      2
    rescue ex
      err.puts "Error in #{path}: cannot read file (#{ex.message}). Fix: check the path and file permissions."
      2
    else
      begin
        migrated = migrate_content(content)
      rescue ex : YAML::ParseException
        err.puts "Error in #{path}: the file is not valid YAML (#{ex.message}). Fix: check indentation and quoting, then retry."
        return 2
      rescue ex : ArgumentError
        err.puts "Error: #{ex.message}"
        return 2
      end

      if in_place
        File.write(path, migrated)
        err.puts "Migrated #{path} to defaults/scopes shape."
      else
        io.puts migrated
      end
      0
    end

    # Converts legacy YAML text to the new shape.
    #
    # Single-org input (`org` + `repos` + `rules`) moves shared
    # rules to `defaults` and repositories to `scopes.main`.
    # Multi-org input (`orgs`) becomes one scope per org.
    # Input already using `scopes` is returned unchanged.
    def self.migrate_content(content : String) : String
      root = YAML.parse(content)
      top = root.as_h? || raise ArgumentError.new("nothing to migrate: the config must be a YAML mapping with `org`/`repos`/`rules` or `orgs`.")
      str_map = {} of String => YAML::Any
      top.each do |k, v|
        str_map[k.as_s] = v if k.as_s?
      end

      if str_map.has_key?("scopes")
        return content.ends_with?("\n") ? content : content + "\n"
      end

      if orgs = str_map["orgs"]?
        return migrate_orgs(orgs)
      end

      migrate_single_org(str_map)
    end

    private def self.migrate_orgs(orgs : YAML::Any) : String
      org_hash = orgs.as_h? || raise ArgumentError.new("nothing to migrate: `orgs` must map organization names to `{repos, rules}`.")
      if org_hash.empty?
        raise ArgumentError.new("nothing to migrate: `orgs` is empty. Fix: add at least one organization with `repos` and `rules`.")
      end

      builder = IO::Memory.new
      builder.puts "# Migrated to defaults/scopes shape."
      builder.puts "# Each organization became one scope; scope rules override defaults per field."
      builder.puts "scopes:"
      org_hash.each do |org_key, org_val|
        org_name = org_key.as_s? || raise ArgumentError.new("nothing to migrate: every `orgs` key must be a string organization name.")
        org_map = org_val.as_h? || raise ArgumentError.new("nothing to migrate: `orgs.#{org_name}` must be a mapping with `repos` and `rules`.")
        org_fields = string_key_map(org_map)

        repos = full_repo_names(org_fields["repos"]?, org_name)
        rules_node = org_fields["rules"]?

        builder.puts "  #{org_name}:"
        builder.puts "    repos:"
        if repos.empty?
          builder.puts "      - #{org_name}/*"
        else
          repos.each { |r| builder.puts "      - #{r}" }
        end
        if rules_node && (rules_hash = rules_node.as_h?) && !rules_hash.empty?
          builder.puts "    rules:"
          append_rules(builder, rules_hash, "      ")
        end
      end
      builder.to_s
    end

    private def self.migrate_single_org(str_map : Hash(String, YAML::Any)) : String
      org = str_map["org"]?.try(&.as_s?)
      repos_node = str_map["repos"]?
      rules_node = str_map["rules"]?

      unless org || repos_node || rules_node
        raise ArgumentError.new("nothing to migrate: expected legacy `org`/`repos`/`rules` keys. Fix: add e.g. `org: myorg` with `repos:` and `rules:`.")
      end

      repos = full_repo_names(repos_node, org)
      if repos.empty? && org
        repos = ["#{org}/*"]
      end
      if repos.empty?
        raise ArgumentError.new("nothing to migrate: no repositories found. Fix: add `repos:` with at least one `org/name` entry, or `org:` for discovery.")
      end

      builder = IO::Memory.new
      builder.puts "# Migrated to defaults/scopes shape."
      builder.puts "# Shared rules live in defaults; scopes.main selects the repositories."
      if rules_node && (rules_hash = rules_node.as_h?) && !rules_hash.empty?
        builder.puts "defaults:"
        builder.puts "  rules:"
        append_rules(builder, rules_hash, "    ")
      end
      builder.puts "scopes:"
      builder.puts "  main:"
      builder.puts "    repos:"
      repos.each { |r| builder.puts "      - #{r}" }
      builder.to_s
    end

    private def self.string_key_map(node : Hash(YAML::Any, YAML::Any)) : Hash(String, YAML::Any)
      result = {} of String => YAML::Any
      node.each do |k, v|
        result[k.as_s] = v if k.as_s?
      end
      result
    end

    private def self.full_repo_names(node : YAML::Any?, org : String?) : Array(String)
      list = node.try(&.as_a?) || [] of YAML::Any
      names = [] of String
      list.each do |entry|
        short = entry.as_s? || next
        short = short.strip
        next if short.empty?
        if short.includes?("/")
          names << short unless names.includes?(short)
        elsif current_org = org
          full = "#{current_org}/#{short}"
          names << full unless names.includes?(full)
        else
          names << short unless names.includes?(short)
        end
      end
      names
    end

    private def self.append_rules(builder : IO, rules_hash : Hash(YAML::Any, YAML::Any), indent : String) : Nil
      rules_hash.each do |type_key, rule_val|
        type_name = type_key.as_s? || next
        builder.puts "#{indent}#{type_name}:"
        rule_map = rule_val.as_h?
        unless rule_map
          builder.puts "#{indent}  merge: only"
          next
        end
        append_rule_fields(builder, rule_map, indent + "  ")
      end
    end

    private def self.append_rule_fields(builder : IO, rule_map : Hash(YAML::Any, YAML::Any), indent : String) : Nil
      order = %w[merge squash rebase pattern name checks linear_history delete_branch]
      fields = string_key_map(rule_map)
      order.each do |field|
        next unless fields.has_key?(field)
        append_known_field(builder, fields[field], field, indent)
      end
      append_extra_fields(builder, fields, order, indent)
    end

    private def self.append_known_field(builder : IO, value : YAML::Any, field : String, indent : String) : Nil
      case field
      when "checks"
        checks = value.as_a? || return
        builder.puts "#{indent}checks:"
        checks.each do |check|
          text = check.as_s? || next
          builder.puts "#{indent}  - #{text.inspect}"
        end
      when "merge", "squash", "rebase"
        text = value.as_s? || return
        if text == "only"
          builder.puts "#{indent}#{field}: only"
        else
          builder.puts "#{indent}#{field}: #{text.inspect}"
        end
      when "pattern", "name"
        text = value.as_s? || return
        builder.puts "#{indent}#{field}: #{text.inspect}"
      when "linear_history", "delete_branch"
        bool = value.as_bool?
        builder.puts "#{indent}#{field}: #{bool}" unless bool.nil?
      end
    end

    private def self.append_extra_fields(builder : IO, fields : Hash(String, YAML::Any), order : Array(String), indent : String) : Nil
      (fields.keys - order).each do |field|
        raw = fields[field].raw
        case raw
        when String
          builder.puts "#{indent}#{field}: #{raw.inspect}"
        when Bool, Int64, Float64
          builder.puts "#{indent}#{field}: #{raw}"
        end
      end
    end
  end
end
