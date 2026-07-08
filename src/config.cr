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

      if orgs = @config.orgs
        orgs.each do |org_name, org_config|
          if org_rules = org_config.rules
            org_rules.each { |name, rule| rule.validate!("#{org_name}.#{name}") }
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

    # Fetches repository list from GitHub for the given organization.
    #
    # @param org [String] GitHub organization name
    # @return [Array(String)] Repository names prefixed with org
    private def discover_repos(org : String) : Array(String)
      client = GitHubClient.new(@token)
      client.list_repos(org).map { |name| "#{org}/#{name}" }
    end
  end
end
