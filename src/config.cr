require "file"
require "yaml"

module Gitorules
  # Loads and parses .gitorules.yml configuration.
  #
  # Reads the YAML file, resolves the repository list (either explicit
  # or auto-discovered via GitHub API), and provides access to the
  # parsed config and authentication token.
  class ConfigLoader
    getter config : Config
    getter token : String

    # Creates a loader from a YAML config file.
    #
    # @param path [String] Path to .gitorules.yml (default: ".gitorules.yml")
    # @param token [String, nil] GitHub token. Falls back to GITHUB_TOKEN env.
    # @raise [RuntimeError] If file not found or GITHUB_TOKEN missing
    def initialize(path : String = ".gitorules.yml", token : String? = nil)
      raw = File.read(path)
      @config = Config.from_yaml(raw)
      @token = token || ENV["GITHUB_TOKEN"]? || raise("GITHUB_TOKEN not set. Export GITHUB_TOKEN or pass --token")
      validate_config!
      validate_merge_methods!
    end

    # Validates all rules in config, collecting errors from each BranchRuleConfig.
    #
    # Iterates single-org rules and multi-org rules. Raises on first
    # validation error, prints warnings to STDERR for unsupported fields.
    #
    # @raise [RuntimeError] If any rule has invalid values
    private def validate_config!
      if rules = @config.rules
        rules.each { |name, rule| rule.validate!(name) }
      end

      if defaults = @config.defaults
        if default_rules = defaults.rules
          default_rules.each { |name, rule| rule.validate!("defaults.#{name}") }
        end
      end

      if scopes = @config.scopes
        scopes.each do |scope_name, scope_config|
          if scope_rules = scope_config.rules
            scope_rules.each { |name, rule| rule.validate!("#{scope_name}.#{name}") }
          end
        end
      end

      if orgs = @config.orgs
        orgs.each do |org_name, org_config|
          if org_rules = org_config.rules
            org_rules.each { |name, rule| rule.validate!("#{org_name}.#{name}") }
          end
        end
      end
    end

    # Validates no conflicting merge methods across all rules.
    #
    # Exits with code 2 if any rule has >1 merge method set to "only".
    private def validate_merge_methods!
      if rules = @config.rules
        rules.each do |name, rule|
          unless rule.validate_merge_methods!
            raise "rules.#{name}: conflicting merge methods detected"
          end
        end
      end

      if defaults = @config.defaults
        if default_rules = defaults.rules
          default_rules.each do |name, rule|
            unless rule.validate_merge_methods!
              raise "defaults.#{name}: conflicting merge methods detected"
            end
          end
        end
      end

      if scopes = @config.scopes
        scopes.each do |scope_name, scope_config|
          if scope_rules = scope_config.rules
            scope_rules.each do |name, rule|
              unless rule.validate_merge_methods!
                raise "scopes.#{scope_name}.#{name}: conflicting merge methods detected"
              end
            end
          end
        end
      end

      if orgs = @config.orgs
        orgs.each do |org_name, org_config|
          if org_rules = org_config.rules
            org_rules.each do |name, rule|
              unless rule.validate_merge_methods!
                raise "rules.#{org_name}.#{name}: conflicting merge methods detected"
              end
            end
          end
        end
      end
    end

    # Resolves full repository names from config.
    #
    # Supports single-org mode (`org` + `repos`) and multi-org mode
    # (`orgs` hash). In multi-org mode each repo name is prefixed
    # with its org. Repos can be auto-discovered via GitHub API
    # when only org name is given without explicit repo list.
    #
    # @return [Array(String)] Full repository names
    # @raise [RuntimeError] If no repos or org configured
    def repo_names : Array(String)
      if orgs = @config.orgs
        names = [] of String
        orgs.each do |org_name, org_config|
          if repos = org_config.repos
            repos.each { |r| names << "#{org_name}/#{r}" }
          else
            names.concat(discover_repos(org_name))
          end
        end
        return names
      end

      if repos = @config.repos
        return repos
      end

      if org = @config.org
        return discover_repos(org)
      end

      raise "No repos or org in config"
    end

    # Returns true when the config uses named scopes.
    def scoped? : Bool
      !@config.scopes.nil?
    end

    # Names of all configured scopes (`["default"]` for legacy configs).
    def scope_names : Array(String)
      ScopeResolver.new(@config).scope_names
    end

    # Repositories belonging to a single scope.
    #
    # Glob selectors expand against *available* when given, otherwise
    # against repositories discovered via the GitHub API. Raises
    # UnknownScopeError for unknown scope names.
    def repos_for_scope(name : String, available : Array(String)? = nil) : Array(String)
      resolver = ScopeResolver.new(@config)
      resolver.validate_scope!(name)

      scopes = @config.scopes
      return repo_names unless scopes

      if avail = available
        return resolver.repos_for_scope(name, avail)
      end

      scope = scopes[name]
      patterns = scope.repos || [] of String
      if patterns.any? { |pattern| ScopeResolver.glob?(pattern) }
        discovered = discover_for_scope(patterns)
        combined = (discovered + patterns.reject { |pattern| ScopeResolver.glob?(pattern) }).uniq!
        return resolver.repos_for_scope(name, combined)
      end

      resolver.repos_for_scope(name, nil)
    end

    # Groups repositories by scope, filtered by CLI `--exclude`.
    #
    # When *requested* is given, only that scope is returned (raises
    # UnknownScopeError otherwise). Preserves config scope order.
    def scope_groups(requested : String?, cli_exclude : Array(String), available : Array(String)? = nil) : Hash(String, Array(String))
      resolver = ScopeResolver.new(@config)
      names = if req = requested
                resolver.validate_scope!(req)
                [req]
              else
                resolver.scope_names
              end

      groups = {} of String => Array(String)
      names.each do |scope_name|
        repos = repos_for_scope(scope_name, available)
        repos = ScopeResolver.filter_exclude(repos, cli_exclude) unless cli_exclude.empty?
        groups[scope_name] = repos
      end
      groups
    end

    # Fetches repository list from GitHub for the given organization.
    #
    # @param org [String] GitHub organization name
    # @return [Array(String)] Repository names prefixed with org
    private def discover_repos(org : String) : Array(String)
      client = GitHubClient.new(@token)
      client.list_repos(org).map { |name| "#{org}/#{name}" }
    end

    # Discovers candidate repositories for scope glob expansion.
    #
    # Collects repos for every non-glob org prefix found in *patterns*.
    private def discover_for_scope(patterns : Array(String)) : Array(String)
      orgs = patterns.compact_map do |pattern|
        parts = pattern.split("/")
        next if parts.size < 2
        org = parts.first.strip
        next if org.empty? || ScopeResolver.glob?(org)
        org
      end.uniq!

      result = [] of String
      orgs.each do |org|
        result.concat(discover_org_repos(org))
      end
      result
    end

    # Lists repositories of a single organization for scope expansion.
    #
    # @param org [String] GitHub organization name
    # @return [Array(String)] Repository names prefixed with org
    # @raise [Exception] With organization context when listing fails
    private def discover_org_repos(org : String) : Array(String)
      discover_repos(org)
    rescue ex
      raise "Failed to list repositories for organization '#{org}': #{ex.message}"
    end
  end
end
