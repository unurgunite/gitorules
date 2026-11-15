module Gitorules
  # Generates `.gitorules.yml` configuration from existing GitHub rulesets.
  #
  # Reverse-engineers the config by fetching current rulesets from one
  # or more repositories and analyzing their rules and conditions.
  class ConfigGenerator
    @client : GitHubClient

    # Standard CI templates for fresh repositories.
    #
    # Keys are template names accepted by `init --template`.
    # Values map repository-relative target paths to file content.
    # Every target is inside the file sync allowlist.
    TEMPLATES = {
      "ruby" => {
        ".github/workflows/ci.yml" => "name: CI\non: [push, pull_request]\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n      - uses: ruby/setup-ruby@v1\n        with:\n          ruby-version-file: .ruby-version\n          bundler-cache: true\n      - run: bundle exec rake\n",
        ".rubocop.yml"             => "AllCops:\n  NewCops: enable\n  TargetRubyVersion: 3.2\n",
        ".ruby-version"            => "3.2.2\n",
      },
      "node" => {
        ".github/workflows/ci.yml" => "name: CI\non: [push, pull_request]\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n      - uses: actions/setup-node@v4\n        with:\n          node-version-file: .nvmrc\n          cache: npm\n      - run: npm ci\n      - run: npm test\n",
        ".nvmrc"                   => "20\n",
      },
      "crystal" => {
        ".github/workflows/ci.yml" => "name: CI\non: [push, pull_request]\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n      - uses: crystal-lang/install-crystal@v1\n      - run: shards install\n      - run: crystal spec\n",
        ".ameba.yml"               => "Globs:\n  - src/**/*.cr\n",
      },
      "gradle" => {
        ".github/workflows/ci.yml" => "name: CI\non: [push, pull_request]\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n      - uses: actions/setup-java@v4\n        with:\n          distribution: temurin\n          java-version: '17'\n      - run: ./gradlew test\n",
      },
    }

    # @param client [GitHubClient] Authenticated GitHub API client
    def initialize(@client : GitHubClient)
    end

    # Returns the file map for a template name.
    #
    # @param name [String] Template name (ruby, node, crystal, gradle)
    # @return [Hash(String, String)?] Target path to content, or nil
    def self.template_files(name : String) : Hash(String, String)?
      TEMPLATES[name]?
    end

    # Returns sorted template names.
    def self.template_names : Array(String)
      TEMPLATES.keys.sort!
    end

    # Scaffolds standard CI files into a repository.
    #
    # Validates every target against the file allowlist before any
    # write. Reuses the Contents-API mechanics (GET with sha, PUT
    # update, sha-match skip, dry-run zero writes).
    #
    # @param template [String] Template name (ruby, node, crystal, gradle)
    # @param repo [String] Full repository name (owner/name)
    # @param io [IO] Output stream (default: STDOUT)
    # @param dry_run [Bool] Plan only, perform zero PUTs
    # @raise [RuntimeError] On unknown template names
    # @raise [FileSyncError] When a template target is not allowlisted
    def scaffold_template(template : String, repo : String, io : IO = STDOUT, dry_run : Bool = false)
      files = self.class.template_files(template)
      raise "Unknown template '#{template}'. Valid templates: #{self.class.template_names.join(", ")}." unless files

      files.each_key { |target| validate_target!(target) }
      files.each do |target, content|
        scaffold_file(repo, target, content, template, io, dry_run)
      end
    end

    private def validate_target!(target : String) : Nil
      return if FileSync.allowed?(target)

      raise FileSyncError.new("Invalid file target '#{target}': only allowlisted paths may be synced")
    end

    # Writes one template file unless the remote copy already matches.
    private def scaffold_file(repo : String, target : String, content : String, template : String, io : IO, dry_run : Bool) : Nil
      local_sha = WorkflowResource.blob_sha(content)
      remote = @client.get_contents(repo, target)
      if remote && remote[:sha] == local_sha
        io.puts "#{repo}: File '#{target}' up to date"
        return
      end

      action = remote ? "update" : "create"
      if dry_run
        io.puts "#{repo}: Would #{action} file '#{target}'"
        return
      end

      @client.put_contents(repo, target, content, remote.try(&.[:sha]), "Scaffold #{target} via gitorules init --template #{template}")
      io.puts "#{repo}: #{action == "create" ? "Created" : "Updated"} file '#{target}'"
    end

    # Repo names with the owning org stripped, for the config's `repos` list.
    private def short_repo_names(repos : Array(String), org : String?) : Array(String)
      names = org ? repos.map(&.lchop("#{org}/")) : repos.dup
      names.uniq!
    end

    # Fetches the full ruleset, or nil when it has no id or the request
    # failed (the failure is reported and counted by the caller).
    private def fetch_full_ruleset(repo : String, rs : Ruleset, err : IO) : Ruleset?
      id = rs.id
      return unless id

      @client.get_ruleset(repo, id)
    rescue ex
      err.puts "Warning: could not fetch ruleset '#{rs.name}' in #{repo}: #{format_http_error(ex)}"
      nil
    end

    # Merges one ruleset's config into the accumulated per-type map.
    private def add_rules(all_rules : Hash(String, BranchRuleConfig), full : Ruleset) : Nil
      type = classify_ruleset(full)
      cfg = extract_config(full)
      all_rules[type] = (existing = all_rules[type]?) ? merge_configs(existing, cfg) : cfg
    end

    # Generates `.gitorules.yml` from existing rulesets.
    #
    # Processes all repos, classifies rulesets by branch pattern,
    # extracts merge/checks config, and outputs YAML to io.
    #
    # @param repos [Array(String)] Full repo names (org/name)
    # @param io [IO] Output stream (default: STDOUT)
    # @param err [IO] Error stream (default: STDERR)
    def generate(repos : Array(String), io : IO = STDOUT, err : IO = STDERR)
      config = Config.new
      config.org = org = extract_org(repos)
      config.repos = short_repo_names(repos, org)

      all_rules = {} of String => BranchRuleConfig
      skipped = collect_rules(repos, all_rules, err)

      if skipped > 0
        err.puts "Warning: #{skipped} branch rule(s) were skipped due to errors"
      end

      config.rules = all_rules unless all_rules.empty?
      print_config(config, skipped, org, io)
    end

    # Fills *all_rules* from every repo's rulesets; returns how many
    # ruleset fetches failed.
    private def collect_rules(repos : Array(String), all_rules : Hash(String, BranchRuleConfig), err : IO) : Int32
      skipped = 0
      repos.each do |repo|
        rulesets = list_rulesets(repo, err)
        if rulesets
          skipped += collect_repo_rulesets(repo, rulesets, all_rules, err)
        else
          skipped += 1
        end
      end
      skipped
    end

    private def list_rulesets(repo : String, err : IO) : Array(Ruleset)?
      @client.list_rulesets(repo)
    rescue ex
      err.puts "Warning: #{repo}: #{format_http_error(ex)}"
      nil
    end

    private def collect_repo_rulesets(repo : String, rulesets : Array(Ruleset), all_rules : Hash(String, BranchRuleConfig), err : IO) : Int32
      skipped = 0
      rulesets.each do |rs|
        full = fetch_full_ruleset(repo, rs, err)
        if full
          add_rules(all_rules, full)
        else
          skipped += 1
        end
      end
      skipped
    end

    private def print_config(config : Config, skipped : Int32, org : String?, io : IO) : Nil
      io.puts "# gitorules configuration"
      io.puts "# Generated by `gitorules init`"
      if skipped > 0
        io.puts "# WARNING: #{skipped} branch rule(s) skipped due to errors"
      end
      if org
        io.puts "#"
        io.puts "# Usage: gitorules status"
        io.puts "#        gitorules apply"
        io.puts "#        gitorules apply --dry-run"
      end
      io.puts ""
      io.puts config.to_yaml
    end

    # Classifies a ruleset into a type key based on branch pattern.
    #
    # Tries known patterns first (default_branch, release, system),
    # then extracts the branch name from the ref pattern. Falls back
    # to a slug generated from the ruleset display name.
    #
    # @param ruleset [Ruleset] Full ruleset with conditions
    # @return [String] Type key (e.g. "default_branch", "release", "system")
    private def classify_ruleset(ruleset : Ruleset) : String
      pattern = extract_include_pattern(ruleset)
      if pattern
        result = known_type(pattern)
        return result if result
      end

      slug = ruleset.name.downcase.gsub(/[^a-z0-9_\/-]+/, "_")
      slug = "custom_#{slug}" unless slug.empty?
      slug = "ruleset" if slug.empty?
      slug
    end

    # Extracts the first ref include pattern from ruleset conditions.
    #
    # Navigates the nested conditions hash to find the first include
    # pattern. Returns nil if conditions or include list is missing.
    #
    # @param ruleset [Ruleset] Full ruleset with conditions
    # @return [String, nil] First include pattern or nil
    private def extract_include_pattern(ruleset : Ruleset) : String?
      ruleset.conditions.try do |c|
        ref = c["ref_name"]?
        inc = ref.try(&.as_h["include"]?.try(&.as_a))
        inc.try(&.first?.try(&.to_s))
      end
    end

    # Maps a known ref pattern to a gitorules type key.
    #
    # Handles standard patterns like master/main, v*, system/*.
    # For unknown refs/heads/ patterns, extracts the branch name.
    # Returns nil for unrecognized patterns.
    #
    # @param pattern [String] Ref include pattern (e.g. "refs/heads/v*")
    # @return [String, nil] Type key or nil if unknown
    private def known_type(pattern : String) : String?
      case pattern
      when "refs/heads/master", "refs/heads/main" then return "default_branch"
      when "refs/heads/v*"                        then return "release"
      when "refs/heads/system/*"                  then return "system"
      end

      if pattern.starts_with?("refs/heads/")
        base = pattern.lchop("refs/heads/")
        base = base.rchop("/*") if base.ends_with?("/*")
        return base unless base.empty?
      end

      nil
    end

    # Extracts branch configuration from a ruleset's rules.
    #
    private def apply_merge_method(cfg : BranchRuleConfig, methods : Array(JSON::Any)?) : BranchRuleConfig
      first = methods.try(&.first?)
      return cfg unless first

      case first.to_s
      when "merge"  then cfg.merge = "only"
      when "squash" then cfg.squash = "only"
      when "rebase" then cfg.rebase = "only"
      end
      cfg
    end

    private def apply_checks(cfg : BranchRuleConfig, checks : Array(JSON::Any)?) : BranchRuleConfig
      contexts = checks.try(&.compact_map { |c| c.as_h["context"]?.try(&.to_s) })
      cfg.checks = contexts unless contexts.nil? || contexts.empty?
      cfg
    end

    # Reads pull_request rule for merge method and
    # required_status_checks rule for check contexts.
    #
    # @param ruleset [Ruleset] Full ruleset with rules
    # @return [BranchRuleConfig] Extracted configuration (may be empty)
    private def extract_config(ruleset : Ruleset) : BranchRuleConfig
      cfg = BranchRuleConfig.new
      cfg.name = ruleset.name

      ruleset.rules.each do |rule|
        next unless params = rule.parameters

        # BranchRuleConfig is a struct: helpers return it instead of mutating.
        case rule.type
        when "pull_request"
          cfg = apply_merge_method(cfg, params["allowed_merge_methods"]?.try(&.as_a))
        when "required_status_checks"
          cfg = apply_checks(cfg, params["required_status_checks"]?.try(&.as_a))
        end
      end

      cfg
    end

    # Merges two configs, preferring non-nil values from the first.
    #
    # Used when the same branch type appears in multiple repos —
    # the first repo's config takes precedence for each field.
    #
    # @param a [BranchRuleConfig] Primary config (takes precedence)
    # @param b [BranchRuleConfig] Secondary config (fallback)
    # @return [BranchRuleConfig] Merged config
    private def merge_configs(a : BranchRuleConfig, b : BranchRuleConfig) : BranchRuleConfig
      merged = BranchRuleConfig.new
      merged.merge = a.merge || b.merge
      merged.squash = a.squash || b.squash
      merged.rebase = a.rebase || b.rebase
      merged.pattern = a.pattern || b.pattern
      merged.checks = a.checks || b.checks
      merged
    end

    # Extracts the org name from the first repository name.
    #
    # Assumes full repo names in "owner/name" format.
    # Returns nil if the repos list is empty.
    #
    # @param repos [Array(String)] Full repository names
    # @return [String, nil] Org name or nil
    private def extract_org(repos : Array(String)) : String?
      parts = repos.first?.to_s.split("/")
      parts.size > 1 ? parts.first : nil
    end

    private def format_http_error(ex : Exception) : String
      case ex.message
      when "Not found"   then "404 Not Found"
      when /^HTTP (\d+)/ then "HTTP #{$1}"
      else                    ex.message.to_s
      end
    end
  end
end
