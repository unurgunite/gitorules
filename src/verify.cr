require "yaml"
require "json"

module Gitorules
  # Converts a YAML scalar to its string form.
  #
  # Strings keep their value, numbers and booleans use `to_s`.
  # Used for matrix axis values when expanding check names.
  def self.yaml_scalar_to_s(node : YAML::Any) : String
    node.raw.to_s
  end

  # Expands workflow templates into concrete GitHub check names.
  #
  # A check name is `"<workflow> / <job>"` with matrix combinations
  # appended as `" (<values>)"`, e.g. `CI / test (20)`. Comparison
  # is exact, never prefix-based.
  module WorkflowChecks
    # Returns produced check names for a template.
    #
    # Appends a warning and falls back to the plain job name when
    # the matrix shape is unknown. Missing workflow names fall back
    # to the workflow key with a warning.
    def self.produced_checks(
      content : String,
      workflow_key : String,
      template_path : String,
      warnings : Array(String),
    ) : Array(String)
      doc = YAML.parse(content)
      workflow_name = workflow_name(doc, workflow_key, template_path, warnings)
      jobs = lint_jobs(doc, template_path, warnings)
      jobs.nil? ? [] of String : expand_jobs(workflow_name, jobs, template_path, warnings)
    rescue ex : YAML::ParseException
      warnings << "in #{template_path}: the template is not valid YAML (#{ex.message}). Fix: check indentation and quoting, then retry."
      [] of String
    end

    # The `jobs:` mapping, or nil (with a warning) when absent or empty.
    private def self.lint_jobs(doc : YAML::Any, template_path : String, warnings : Array(String)) : Hash(YAML::Any, YAML::Any)?
      jobs = fetch_hash(doc, "jobs")
      return jobs if jobs && !jobs.empty?

      warnings << "in #{template_path}: no `jobs:` mapping found, nothing is produced. Fix: add at least one job to the template."
      nil
    end

    # One check name set per job, de-duplicated.
    private def self.expand_jobs(workflow_name : String, jobs : Hash(YAML::Any, YAML::Any), template_path : String, warnings : Array(String)) : Array(String)
      result = [] of String
      jobs.each do |job_key, job_value|
        job_id = job_key.as_s? || next
        result.concat(expand_job(workflow_name, job_id, job_value, template_path, warnings))
      end
      result.uniq!
    end

    # Resolves the workflow display name.
    private def self.workflow_name(doc : YAML::Any, workflow_key : String, template_path : String, warnings : Array(String)) : String
      if name = fetch_key(doc, "name").try(&.as_s?)
        return name unless name.strip.empty?
      end
      fallback = File.basename(workflow_key, File.extname(workflow_key))
      fallback = workflow_key if fallback.empty?
      warnings << "in #{template_path}: missing workflow `name:`, using #{fallback.inspect} as the workflow name. Fix: add `name: #{fallback}` to the template."
      fallback
    end

    # Expands one job, including its matrix combinations.
    private def self.expand_job(workflow_name : String, job_id : String, job_node : YAML::Any, template_path : String, warnings : Array(String)) : Array(String)
      base = "#{workflow_name} / #{job_id}"
      strategy = fetch_key(job_node, "strategy")
      matrix = strategy.try { |node| fetch_key(node, "matrix") }
      return [base] unless matrix
      expand_matrix(workflow_name, job_id, base, matrix, template_path, warnings)
    end

    # Expands a matrix node to concrete check names.
    private def self.expand_matrix(workflow_name : String, job_id : String, base : String, matrix : YAML::Any, template_path : String, warnings : Array(String)) : Array(String)
      matrix_hash = matrix.as_h?
      unless matrix_hash
        matrix_shape_warning(warnings, template_path, job_id, base)
        return [base]
      end
      parsed = parse_matrix(matrix_hash, job_id, base, template_path, warnings)
      return [base] unless parsed
      axes, includes, excludes = parsed

      result = [] of String
      unless axes.empty?
        combos = apply_excludes(cartesian(axes), axes, excludes)
        combos.each { |combo| result << matrix_label(base, combo) }
      end
      includes.each { |values| result << matrix_label(base, values) }
      result.uniq!
    end

    # Check-name suffix for one matrix combination.
    private def self.matrix_label(base : String, combo : Array(String)) : String
      combo.empty? ? base : "#{base} (#{combo.join(", ")})"
    end

    # Records the shared "unknown matrix shape" warning. A nil *key* means
    # the whole matrix node was unusable.
    private def self.matrix_shape_warning(warnings : Array(String), template_path : String, job_id : String, base : String, key : String? = nil) : Nil
      location = key ? "jobs.#{job_id}.strategy.matrix.#{key}" : "jobs.#{job_id}.strategy.matrix"
      warnings << "in #{template_path} at #{location}: unknown matrix shape, using plain job name #{base.inspect}. Fix: use `matrix: {key: [values]}` or `include: [...]` shapes."
    end

    # Parses matrix axes, include and exclude lists.
    #
    # Returns nil when the shape is unknown (caller falls back to
    # the plain job name; the warning is already recorded).
    private def self.parse_matrix(matrix_hash : Hash(YAML::Any, YAML::Any), job_id : String, base : String, template_path : String, warnings : Array(String)) : {Array(Tuple(String, Array(String))), Array(Array(String)), Array(Hash(String, String))}?
      axes = [] of Tuple(String, Array(String))
      includes = [] of Array(String)
      excludes = [] of Hash(String, String)
      matrix_hash.each do |key_any, value_any|
        key = key_any.as_s? || next
        next if collect_matrix_axis(key, value_any, axes, job_id, base, template_path, warnings)
        return if collect_matrix_extra(key, value_any, includes, excludes, job_id, base, template_path, warnings) == :invalid
      end
      return if axes.empty? && includes.empty?

      {axes, includes, excludes}
    end

    # Appends a plain axis entry. True when *key* was an axis key.
    private def self.collect_matrix_axis(key : String, value_any : YAML::Any, axes : Array(Tuple(String, Array(String))), job_id : String, base : String, template_path : String, warnings : Array(String)) : Bool
      return false if key.in?("include", "exclude")

      axis = parse_axis(key, value_any, job_id, base, template_path, warnings)
      axes << axis if axis
      true
    end

    # Appends an `include:`/`exclude:` entry list. Returns :invalid when the
    # list shape is unusable (warning already recorded).
    private def self.collect_matrix_extra(key : String, value_any : YAML::Any, includes : Array(Array(String)), excludes : Array(Hash(String, String)), job_id : String, base : String, template_path : String, warnings : Array(String)) : Symbol
      list = matrix_entry_list(value_any, job_id, base, template_path, warnings, key)
      return :invalid unless list

      if key == "include"
        list.each { |entry| includes << matrix_include_values(entry) unless entry.empty? }
      else
        list.each { |entry| excludes << matrix_exclude_values(entry) unless entry.empty? }
      end
      :ok
    end

    # One matrix axis; nil (with the warning recorded) for a non-list value.
    private def self.parse_axis(key : String, value_any : YAML::Any, job_id : String, base : String, template_path : String, warnings : Array(String)) : Tuple(String, Array(String))?
      values = value_any.as_a?
      return {key, values.map { |entry| Gitorules.yaml_scalar_to_s(entry) }} if values

      matrix_shape_warning(warnings, template_path, job_id, base, key)
      nil
    end

    # Validates a matrix `include:`/`exclude:` list, returning its entry
    # mappings or nil (with the warning recorded) for a bad shape.
    private def self.matrix_entry_list(node : YAML::Any, job_id : String, base : String, template_path : String, warnings : Array(String), key : String) : Array(Hash(YAML::Any, YAML::Any))?
      list = node.as_a?
      return unless list
      hashes = list.compact_map(&.as_h?)
      return hashes if hashes.size == list.size

      matrix_shape_warning(warnings, template_path, job_id, base, key)
      nil
    end

    # Values of one `include:` entry, in declaration order.
    private def self.matrix_include_values(entry : Hash(YAML::Any, YAML::Any)) : Array(String)
      entry.values.map { |value| Gitorules.yaml_scalar_to_s(value) }
    end

    # Key-value map of one `exclude:` entry.
    private def self.matrix_exclude_values(entry : Hash(YAML::Any, YAML::Any)) : Hash(String, String)
      mapping = {} of String => String
      entry.each do |key_any, value_any|
        key = key_any.as_s?
        mapping[key] = Gitorules.yaml_scalar_to_s(value_any) if key
      end
      mapping
    end

    # Computes the cartesian product of matrix axes.
    private def self.cartesian(axes : Array(Tuple(String, Array(String)))) : Array(Array(String))
      combos = [[] of String]
      axes.each do |(_, values)|
        next_combos = [] of Array(String)
        combos.each do |prefix|
          values.each do |value|
            next_combos << (prefix + [value])
          end
        end
        combos = next_combos
      end
      combos
    end

    # Removes combinations matched by `exclude:` entries.
    private def self.apply_excludes(combos : Array(Array(String)), axes : Array(Tuple(String, Array(String))), excludes : Array(Hash(String, String))) : Array(Array(String))
      return combos if excludes.empty? || axes.empty?
      keys = axes.map(&.[0])
      combos.reject do |combo|
        mapping = {} of String => String
        keys.each_with_index { |key, index| mapping[key] = combo[index] }
        excludes.any? do |entry|
          entry.all? { |key, value| mapping[key]? == value }
        end
      end
    end

    # Fetches a mapping value by string key.
    private def self.fetch_key(node : YAML::Any, key : String) : YAML::Any?
      hash = node.as_h?
      return unless hash
      hash.each do |k, v|
        return v if k.as_s? == key
      end
      nil
    end

    # Fetches a nested mapping by string key.
    private def self.fetch_hash(node : YAML::Any, key : String) : Hash(YAML::Any, YAML::Any)?
      fetch_key(node, key).try(&.as_h?)
    end
  end

  # Per-scope consistency report.
  struct ScopeReport
    include JSON::Serializable

    # Scope name (`default` for legacy configs).
    property scope : String
    # Required checks from effective branch rules (sorted, unique).
    property required : Array(String)
    # Checks produced by the scope workflows (sorted, unique).
    property produced : Array(String)
    # Required checks with no producing workflow.
    property missing : Array(String)
    # Produced checks with no matching requirement.
    property extra : Array(String)
    # Non-fatal notes (matrix fallbacks, template hints).
    property warnings : Array(String)
    # True when every required check is produced.
    property? ok : Bool = true

    def initialize(@scope : String, @required : Array(String) = [] of String, @produced : Array(String) = [] of String, @missing : Array(String) = [] of String, @extra : Array(String) = [] of String, @warnings : Array(String) = [] of String, @ok : Bool = true)
      @ok = @missing.empty?
    end
  end

  # Cross-checks required branch checks against synced workflows.
  #
  # Every exact required check in `rules.<scope>.<type>.checks` must be
  # produced by a job in the scope workflows. Missing checks are errors,
  # extra jobs are warnings. Glob patterns are skipped (they match
  # locally and never become ruleset checks).
  module Consistency
    # Checks all scopes in *config*.
    #
    # Returns reports plus lint-shaped errors and warnings. Scopes
    # without workflows are skipped silently.
    def self.check_all(config : Config, base_dir : String, config_path : String) : Tuple(Array(ScopeReport), Array(String), Array(String))
      reports = [] of ScopeReport
      errors = [] of String
      warnings = [] of String
      scope_names(config).each do |scope_name|
        report, scope_errors, scope_warnings = check_scope(config, scope_name, base_dir, config_path)
        # Scopes without workflows produce no report.
        next if report.nil?
        if scoped = report
          reports << scoped
          errors.concat(scope_errors)
          warnings.concat(scope_warnings)
        end
      end
      {reports, errors, warnings}
    end

    # Names of all scopes (`["default"]` for legacy configs).
    def self.scope_names(config : Config) : Array(String)
      if scopes = config.scopes
        scopes.keys
      elsif orgs = config.orgs
        orgs.keys
      else
        ["default"]
      end
    end

    # Checks one scope. Returns nil when the scope has no workflows.
    def self.check_scope(config : Config, scope_name : String, base_dir : String, config_path : String) : Tuple(ScopeReport?, Array(String), Array(String))
      errors = [] of String
      warnings = [] of String
      required = required_checks(config, scope_name)
      workflows = workflows_for_scope(config, scope_name)
      return {nil, errors, warnings} if workflows.empty?

      produced, produce_warnings = produced_checks(workflows, base_dir, config_path, scope_name, errors)
      warnings.concat(produce_warnings)

      required_names = required.map(&.[:check]).uniq!.sort!
      produced_names = produced.uniq!.sort!
      missing = required_names - produced_names
      extra = produced_names - required_names
      report_missing(missing, required, produced_names, scope_name, config_path, errors)
      report_extra(extra, scope_name, config, config_path, warnings)

      {build_report(scope_name, required_names, produced_names, missing, extra, produce_warnings), errors, warnings}
    end

    private def self.build_report(scope_name : String, required_names : Array(String), produced_names : Array(String), missing : Array(String), extra : Array(String), produce_warnings : Array(String)) : ScopeReport
      ScopeReport.new(
        scope: scope_name,
        required: required_names,
        produced: produced_names,
        missing: missing.sort,
        extra: extra.sort,
        warnings: produce_warnings.dup
      )
    end

    # Records one error per required check that no workflow produces,
    # pointing at the rule that requires it when known.
    private def self.report_missing(missing : Array(String), required : Array(NamedTuple(check: String, location: String)), produced_names : Array(String), scope_name : String, config_path : String, errors : Array(String)) : Nil
      locations = {} of String => String
      required.each { |entry| locations[entry[:check]] ||= entry[:location] }

      missing.each do |check|
        location = locations[check]? || "scopes.#{scope_name}.rules.*.checks"
        errors << "in #{config_path} at #{location}: required check #{check.inspect} is not produced by any workflow in scope #{scope_name.inspect}. Fix: rename the check or update the template. Produced checks in scope #{scope_name.inspect}: #{format_list(produced_names)}"
      end
    end

    # Records one warning per produced check that no rule requires.
    private def self.report_extra(extra : Array(String), scope_name : String, config : Config, config_path : String, warnings : Array(String)) : Nil
      extra.each do |check|
        warnings << "in #{config_path} at #{scope_workflows_location(config, scope_name)}: produced check #{check.inspect} has no matching requirement in scope #{scope_name.inspect}. Fix: add it to #{scope_rules_prefix(config, scope_name)}.*.checks if it should be required, or ignore this warning."
      end
    end

    # Collects exact required checks for a scope with locations.
    def self.required_checks(config : Config, scope_name : String) : Array(NamedTuple(check: String, location: String))
      entries = [] of NamedTuple(check: String, location: String)
      effective_rules(config, scope_name).each do |type_name, rule|
        checks = rule.checks || next
        location = rules_location(config, scope_name, type_name)
        checks.each do |check|
          next if check.strip.empty?
          next if glob_check?(check)
          entries << {check: check, location: location}
        end
      end
      entries
    end

    # Effective branch rules for a scope.
    def self.effective_rules(config : Config, scope_name : String) : Hash(String, BranchRuleConfig)
      if scopes = config.scopes
        base = config.defaults.try(&.rules)
        if scope = scopes[scope_name]?
          return ScopeResolver.merge_rules(base, scope.rules) || {} of String => BranchRuleConfig
        end
        return base || {} of String => BranchRuleConfig
      end
      if orgs = config.orgs
        return orgs[scope_name]?.try(&.rules) || {} of String => BranchRuleConfig
      end
      config.rules || {} of String => BranchRuleConfig
    end

    # Workflows for a scope (scope entries win per key).
    def self.workflows_for_scope(config : Config, scope_name : String) : Hash(String, WorkflowConfig)
      if scopes = config.scopes
        base = parse_workflows_any(config.defaults.try(&.workflows))
        if top = config.workflows
          top.each { |key, value| base[key] = value unless base.has_key?(key) }
        end
        if scope = scopes[scope_name]?
          overrides = parse_workflows_any(scope.workflows)
          overrides.each { |key, value| base[key] = value }
        end
        return base
      end
      if orgs = config.orgs
        return orgs[scope_name]?.try(&.workflows) || {} of String => WorkflowConfig
      end
      config.workflows || {} of String => WorkflowConfig
    end

    # Parses a `workflows:` YAML mapping into typed entries.
    def self.parse_workflows_any(node : YAML::Any?) : Hash(String, WorkflowConfig)
      result = {} of String => WorkflowConfig
      hash = node.try(&.as_h?) || return result
      hash.each do |key_any, value_any|
        key = key_any.as_s? || next
        entry = WorkflowConfig.new
        if value_hash = value_any.as_h?
          value_hash.each do |field_key, field_value|
            if field_key.as_s? == "source"
              entry.source = field_value.as_s?
            end
          end
        end
        result[key] = entry
      end
      result
    end

    # Reads templates and expands produced checks.
    private def self.produced_checks(workflows : Hash(String, WorkflowConfig), base_dir : String, config_path : String, scope_name : String, errors : Array(String)) : Tuple(Array(String), Array(String))
      produced = [] of String
      warnings = [] of String
      workflows.each do |key, entry|
        template_path = read_template(entry.source, key, base_dir, config_path, scope_name, errors) || next
        produced.concat(WorkflowChecks.produced_checks(File.read(template_path), key, template_path, warnings))
      end
      {produced, warnings}
    end

    # Resolves and reads a local template, returning its path or nil after
    # recording why it cannot be read.
    private def self.read_template(source : String?, key : String, base_dir : String, config_path : String, scope_name : String, errors : Array(String)) : String?
      location = scope_workflows_location(nil, scope_name)
      if source.nil? || source.strip.empty?
        errors << "in #{config_path} at #{location}.#{key}: workflow #{key.inspect} has no source configured. Fix: add `source: templates/#{key}` or remove the entry."
        return
      end
      # Remote sources resolve over the API, not the local disk. Offline
      # consistency checks cannot fetch them; syntax is already validated
      # by `lint_workflows`, so skip silently.
      return if remote_source?(source)

      template_path = resolve_source(source, base_dir)
      unless File.exists?(template_path)
        errors << "in #{config_path} at #{location}.#{key}: template source #{source.inspect} not found (looked at #{template_path.inspect}). Fix: create the template or fix the `source:` path."
        return
      end
      template_path
    end

    # Resolves a template source against *base_dir*.
    private def self.resolve_source(source : String, base_dir : String) : String
      return source if Path[source].absolute?
      File.join(base_dir, source)
    end

    # True for `owner/repo@ref:path` references (resolved over the API).
    #
    # Malformed sources are reported by `lint_workflows`; here they
    # fall through to the local-disk check and its error message.
    private def self.remote_source?(source : String) : Bool
      parsed = TemplateSource.parse(source)
      parsed.kind.remote?
    rescue WorkflowError
      false
    end

    # Location prefix for a branch-type checks key.
    private def self.rules_location(config : Config, scope_name : String, type_name : String) : String
      if config.scopes
        "scopes.#{scope_name}.rules.#{type_name}.checks"
      elsif config.orgs
        "orgs.#{scope_name}.rules.#{type_name}.checks"
      else
        "rules.#{type_name}.checks"
      end
    end

    # Location of a scope workflows section.
    private def self.scope_workflows_location(config : Config?, scope_name : String) : String
      if cfg = config
        if cfg.scopes
          return "scopes.#{scope_name}.workflows"
        elsif cfg.orgs
          return "orgs.#{scope_name}.workflows"
        end
      else
        return "scopes.#{scope_name}.workflows" if scope_name != "default"
      end
      scope_name == "default" ? "workflows" : "scopes.#{scope_name}.workflows"
    end

    # Prefix for rule keys in messages.
    private def self.scope_rules_prefix(config : Config, scope_name : String) : String
      if config.scopes
        "scopes.#{scope_name}.rules"
      elsif config.orgs
        "orgs.#{scope_name}.rules"
      else
        "rules"
      end
    end

    # Formats a check list for messages.
    private def self.format_list(checks : Array(String)) : String
      return "[]" if checks.empty?
      "[" + checks.map(&.inspect).join(", ") + "]"
    end

    # True when a check contains glob characters.
    private def self.glob_check?(text : String) : Bool
      text.includes?('*') || text.includes?('?') || text.includes?('[')
    end
  end

  # Offline verifier for the `verify` command.
  #
  # Dry-run report of required-vs-produced checks per scope.
  # Thin wiring over `Consistency`; all logic lives there.
  class Verifier
    # Verifies the file at *path*.
    #
    # Prints a text report or JSON with *json*. Returns 2 when any
    # required check is missing or the file cannot be read, 0
    # otherwise (warnings do not affect the exit code).
    def self.verify_file(path : String, scope_filter : String? = nil, json : Bool = false, io : IO = STDOUT, err : IO = STDERR) : Int32
      content = File.read(path)
    rescue File::NotFoundError
      err.puts "Error in #{path}: file not found. Fix: create the file or pass --config PATH to an existing config."
      2
    rescue ex
      err.puts "Error in #{path}: cannot read file (#{ex.message}). Fix: check the path and file permissions."
      2
    else
      base_dir = File.dirname(File.expand_path(path))
      verify_content(content, path, base_dir, scope_filter, json, io, err)
    end

    # Scope names to verify: all of them, or just the requested one.
    # Returns nil (after printing the error) when the filter is unknown.
    private def self.filtered_scope_names(names : Array(String), scope_filter : String?, err : IO) : Array(String)?
      filter = scope_filter
      if filter.nil?
        names
      elsif names.includes?(filter)
        [filter]
      else
        err.puts "Error: unknown scope '#{filter}'. Available scopes: #{names.join(", ")}. Check the `scopes:` section in your config file or run without --scope to use all scopes."
        nil
      end
    end

    # Verifies YAML *content* and prints the report.
    def self.verify_content(content : String, path : String = ".gitorules.yml", base_dir : String = Dir.current, scope_filter : String? = nil, json : Bool = false, io : IO = STDOUT, err : IO = STDERR) : Int32
      config = Config.from_yaml(content)
    rescue ex
      err.puts "Error in #{path}: cannot parse config (#{ex.message}). Fix: check indentation and quoting, then retry."
      2
    else
      names = filtered_scope_names(Consistency.scope_names(config), scope_filter, err)
      return 2 unless names

      reports, errors, warnings = collect_reports(config, names, base_dir, path)
      warnings.each { |line| err.puts "Warning: #{line}" }
      json ? print_json(reports, io) : print_text(reports, io)
      report_result(reports, errors, json, io, err)
    end

    # Runs the consistency check for every scope, keeping the results whose
    # scope has workflows.
    private def self.collect_reports(config : Config, names : Array(String), base_dir : String, path : String) : {Array(ScopeReport), Array(String), Array(String)}
      reports = [] of ScopeReport
      errors = [] of String
      warnings = [] of String
      names.each do |scope_name|
        report, scope_errors, scope_warnings = Consistency.check_scope(config, scope_name, base_dir, path)
        next unless report

        reports << report
        errors.concat(scope_errors)
        warnings.concat(scope_warnings)
      end
      {reports, errors, warnings}
    end

    # Prints the closing line or the errors, and returns the exit code.
    private def self.report_result(reports : Array(ScopeReport), errors : Array(String), json : Bool, io : IO, err : IO) : Int32
      if reports.empty?
        io.puts "No scopes with workflows found, nothing to verify"
        return 0
      end
      if errors.empty?
        io.puts "OK: all required checks are produced" unless json
        return 0
      end

      errors.each { |line| err.puts "Error: #{line}" } unless json
      2
    end

    # Prints a human-readable per-scope report.
    private def self.print_text(reports : Array(ScopeReport), io : IO) : Nil
      reports.each do |report|
        io.puts "Scope: #{report.scope}"
        io.puts "  Required (#{report.required.size}): #{format_checks(report.required)}"
        io.puts "  Produced (#{report.produced.size}): #{format_checks(report.produced)}"
        if report.missing.empty? && report.extra.empty?
          io.puts "  OK: all required checks are produced"
        else
          print_list("Missing", report.missing, io) unless report.missing.empty?
          print_list("Extra", report.extra, io) unless report.extra.empty?
        end
      end
    end

    private def self.print_list(label : String, checks : Array(String), io : IO) : Nil
      io.puts "  #{label} (#{checks.size}): #{format_checks(checks)}"
    end

    # Prints a machine-readable JSON report.
    private def self.print_json(reports : Array(ScopeReport), io : IO) : Nil
      io.puts reports.to_json
    end

    # Formats a check list for text output.
    private def self.format_checks(checks : Array(String)) : String
      return "(none)" if checks.empty?
      checks.map(&.inspect).join(", ")
    end
  end
end
