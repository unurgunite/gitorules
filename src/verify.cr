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
      jobs = fetch_hash(doc, "jobs")
      unless jobs
        warnings << "in #{template_path}: no `jobs:` mapping found, nothing is produced. Fix: add at least one job to the template."
        return [] of String
      end
      if jobs.empty?
        warnings << "in #{template_path}: no `jobs:` mapping found, nothing is produced. Fix: add at least one job to the template."
        return [] of String
      end
      result = [] of String
      jobs.each do |job_key, job_value|
        job_id = job_key.as_s? || next
        result.concat(expand_job(workflow_name, job_id, job_value, template_path, warnings))
      end
      result.uniq!
    rescue ex : YAML::ParseException
      warnings << "in #{template_path}: the template is not valid YAML (#{ex.message}). Fix: check indentation and quoting, then retry."
      [] of String
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
        warnings << "in #{template_path} at jobs.#{job_id}.strategy.matrix: unknown matrix shape, using plain job name #{base.inspect}. Fix: use `matrix: {key: [values]}` or `include: [...]` shapes."
        return [base]
      end
      parsed = parse_matrix(matrix_hash, job_id, base, template_path, warnings)
      return [base] unless parsed
      axes, includes, excludes = parsed
      result = [] of String
      unless axes.empty?
        combos = cartesian(axes)
        combos = apply_excludes(combos, axes, excludes)
        combos.each do |combo|
          result << (combo.empty? ? base : "#{base} (#{combo.join(", ")})")
        end
      end
      includes.each do |values|
        result << "#{base} (#{values.join(", ")})"
      end
      result.uniq!
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
        case key
        when "include"
          parsed = parse_include(value_any, job_id, base, template_path, warnings)
          return unless parsed
          includes.concat(parsed)
        when "exclude"
          parsed = parse_exclude(value_any, job_id, base, template_path, warnings)
          return unless parsed
          excludes.concat(parsed)
        else
          values = value_any.as_a?
          unless values
            warnings << "in #{template_path} at jobs.#{job_id}.strategy.matrix.#{key}: unknown matrix shape, using plain job name #{base.inspect}. Fix: use `matrix: {key: [values]}` or `include: [...]` shapes."
            return
          end
          axes << {key, values.map { |entry| Gitorules.yaml_scalar_to_s(entry) }}
        end
      end
      if axes.empty? && includes.empty?
        warnings << "in #{template_path} at jobs.#{job_id}.strategy.matrix: unknown matrix shape, using plain job name #{base.inspect}. Fix: use `matrix: {key: [values]}` or `include: [...]` shapes."
        return
      end
      {axes, includes, excludes}
    end

    # Parses an `include:` list to value combinations.
    private def self.parse_include(node : YAML::Any, job_id : String, base : String, template_path : String, warnings : Array(String)) : Array(Array(String))?
      list = node.as_a?
      unless list
        warnings << "in #{template_path} at jobs.#{job_id}.strategy.matrix.include: unknown matrix shape, using plain job name #{base.inspect}. Fix: use `matrix: {key: [values]}` or `include: [...]` shapes."
        return
      end
      result = [] of Array(String)
      list.each do |entry|
        entry_hash = entry.as_h?
        unless entry_hash
          warnings << "in #{template_path} at jobs.#{job_id}.strategy.matrix.include: unknown matrix shape, using plain job name #{base.inspect}. Fix: use `matrix: {key: [values]}` or `include: [...]` shapes."
          return
        end
        values = [] of String
        entry_hash.each_value do |value|
          values << Gitorules.yaml_scalar_to_s(value)
        end
        result << values unless values.empty?
      end
      result
    end

    # Parses an `exclude:` list to key-value maps.
    private def self.parse_exclude(node : YAML::Any, job_id : String, base : String, template_path : String, warnings : Array(String)) : Array(Hash(String, String))?
      list = node.as_a?
      unless list
        warnings << "in #{template_path} at jobs.#{job_id}.strategy.matrix.exclude: unknown matrix shape, using plain job name #{base.inspect}. Fix: use `matrix: {key: [values]}` or `include: [...]` shapes."
        return
      end
      result = [] of Hash(String, String)
      list.each do |entry|
        entry_hash = entry.as_h?
        unless entry_hash
          warnings << "in #{template_path} at jobs.#{job_id}.strategy.matrix.exclude: unknown matrix shape, using plain job name #{base.inspect}. Fix: use `matrix: {key: [values]}` or `include: [...]` shapes."
          return
        end
        mapping = {} of String => String
        entry_hash.each do |key_any, value_any|
          if key = key_any.as_s?
            mapping[key] = Gitorules.yaml_scalar_to_s(value_any)
          end
        end
        result << mapping unless mapping.empty?
      end
      result
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

      locations = {} of String => String
      required.each { |entry| locations[entry[:check]] ||= entry[:location] }

      missing.each do |check|
        location = locations[check]? || "scopes.#{scope_name}.rules.*.checks"
        errors << "in #{config_path} at #{location}: required check #{check.inspect} is not produced by any workflow in scope #{scope_name.inspect}. Fix: rename the check or update the template. Produced checks in scope #{scope_name.inspect}: #{format_list(produced_names)}"
      end

      extra.each do |check|
        warnings << "in #{config_path} at #{scope_workflows_location(config, scope_name)}: produced check #{check.inspect} has no matching requirement in scope #{scope_name.inspect}. Fix: add it to #{scope_rules_prefix(config, scope_name)}.*.checks if it should be required, or ignore this warning."
      end

      report = ScopeReport.new(
        scope: scope_name,
        required: required_names,
        produced: produced_names,
        missing: missing.sort,
        extra: extra.sort,
        warnings: produce_warnings.dup
      )
      {report, errors, warnings}
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
        source = entry.source
        if source.nil? || source.strip.empty?
          errors << "in #{config_path} at #{scope_workflows_location(nil, scope_name)}.#{key}: workflow #{key.inspect} has no source configured. Fix: add `source: templates/#{key}` or remove the entry."
          next
        end
        template_path = resolve_source(source, base_dir)
        unless File.exists?(template_path)
          errors << "in #{config_path} at #{scope_workflows_location(nil, scope_name)}.#{key}: template source #{source.inspect} not found (looked at #{template_path.inspect}). Fix: create the template or fix the `source:` path."
          next
        end
        begin
          content = File.read(template_path)
        rescue ex
          errors << "in #{config_path} at #{scope_workflows_location(nil, scope_name)}.#{key}: cannot read template #{source.inspect} (#{ex.message}). Fix: check the path and file permissions."
          next
        end
        produced.concat(WorkflowChecks.produced_checks(content, key, template_path, warnings))
      end
      {produced, warnings}
    end

    # Resolves a template source against *base_dir*.
    private def self.resolve_source(source : String, base_dir : String) : String
      return source if Path[source].absolute?
      File.join(base_dir, source)
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

    # Verifies YAML *content* and prints the report.
    def self.verify_content(content : String, path : String = ".gitorules.yml", base_dir : String = Dir.current, scope_filter : String? = nil, json : Bool = false, io : IO = STDOUT, err : IO = STDERR) : Int32
      config = Config.from_yaml(content)
    rescue ex
      err.puts "Error in #{path}: cannot parse config (#{ex.message}). Fix: check indentation and quoting, then retry."
      2
    else
      names = Consistency.scope_names(config)
      if filter = scope_filter
        unless names.includes?(filter)
          err.puts "Error: unknown scope '#{filter}'. Available scopes: #{names.join(", ")}. Check the `scopes:` section in your config file or run without --scope to use all scopes."
          return 2
        end
        names = [filter]
      end
      reports = [] of ScopeReport
      errors = [] of String
      warnings = [] of String
      names.each do |scope_name|
        report, scope_errors, scope_warnings = Consistency.check_scope(config, scope_name, base_dir, path)
        next if report.nil?
        if scoped = report
          reports << scoped
          errors.concat(scope_errors)
          warnings.concat(scope_warnings)
        end
      end
      warnings.each { |line| err.puts "Warning: #{line}" }
      if json
        print_json(reports, io)
      else
        print_text(reports, io)
      end
      if reports.empty?
        io.puts "No scopes with workflows found, nothing to verify"
        return 0
      end
      if errors.empty?
        io.puts "OK: all required checks are produced" unless json
        0
      else
        errors.each { |line| err.puts "Error: #{line}" } unless json
        2
      end
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
          unless report.missing.empty?
            io.puts "  Missing (#{report.missing.size}): #{format_checks(report.missing)}"
          end
          unless report.extra.empty?
            io.puts "  Extra (#{report.extra.size}): #{format_checks(report.extra)}"
          end
        end
      end
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
