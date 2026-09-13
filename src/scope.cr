module Gitorules
  # Raised when a requested scope name does not exist in the config.
  #
  # Message states what is wrong and how to fix it in plain language.
  class UnknownScopeError < Exception
    getter requested : String
    getter available : Array(String)

    def initialize(@requested : String, @available : Array(String))
      super("Unknown scope '#{@requested}'. Available scopes: #{@available.join(", ")}. Check the `scopes:` section in your config file or run without --scope to use all scopes.")
    end
  end

  # Resolves repositories and effective rules for named scopes.
  #
  # Scopes group repositories via glob selectors (e.g. `unurgunite/*-api`)
  # with an explicit `exclude` list. Effective branch rules merge
  # `defaults` with scope-specific rules, where scope values win per field.
  class ScopeResolver
    VALID_ONLY_VALUES = ["branch", "labels", "workflows"]

    def initialize(@config : Config)
    end

    # Names of all configured scopes, or `["default"]` for legacy configs.
    def scope_names : Array(String)
      if scopes = @config.scopes
        scopes.keys
      else
        ["default"]
      end
    end

    def has_scope?(name : String) : Bool
      scope_names.includes?(name)
    end

    # Raises UnknownScopeError unless *name* exists.
    def validate_scope!(name : String) : Nil
      return if has_scope?(name)
      raise UnknownScopeError.new(name, scope_names)
    end

    # Returns true if *repo* belongs to *scope_name*.
    #
    # A repo matches when any `repos` selector matches and no `exclude`
    # entry matches. Selectors support `*`, `?` and `[...]` globs.
    def repo_in_scope?(repo : String, scope_name : String) : Bool
      validate_scope!(scope_name)
      scopes = @config.scopes
      return true unless scopes

      scope = scopes[scope_name]
      excludes = scope.exclude || [] of String
      return false if excluded?(repo, excludes)

      patterns = scope.repos || [] of String
      patterns.any? { |pattern| self.class.matches?(pattern, repo) }
    end

    # First scope owning *repo*, or nil when no scope matches.
    def scope_for_repo(repo : String) : String?
      scopes = @config.scopes
      return "default" unless scopes

      scopes.each_key do |name|
        return name if repo_in_scope?(repo, name)
      end
      nil
    end

    # Repositories belonging to *scope_name*.
    #
    # Glob selectors expand against *available*. Without *available*,
    # only explicit (non-glob) entries are returned.
    def repos_for_scope(scope_name : String, available : Array(String)? = nil) : Array(String)
      validate_scope!(scope_name)
      scopes = @config.scopes
      return available ? available.dup : [] of String unless scopes

      scope = scopes[scope_name]
      patterns = scope.repos || [] of String
      excludes = scope.exclude || [] of String

      candidates = if avail = available
                     result = [] of String
                     patterns.each do |pattern|
                       if self.class.glob?(pattern)
                         avail.each do |repo|
                           result << repo if self.class.matches?(pattern, repo) && !result.includes?(repo)
                         end
                       else
                         result << pattern unless result.includes?(pattern)
                       end
                     end
                     result
                   else
                     patterns.reject { |pattern| self.class.glob?(pattern) }
                   end

      candidates.reject { |repo| excluded?(repo, excludes) }.uniq!
    end

    # Effective branch rules for *repo*.
    #
    # Merges `defaults.rules` with the owning scope's rules. When
    # *scope_name* is given, merges against that scope directly.
    # Legacy configs (no `scopes`) fall back to `org`/`orgs` lookup.
    def effective_rules(repo : String, scope_name : String? = nil) : Hash(String, BranchRuleConfig)?
      scopes = @config.scopes
      unless scopes
        return @config.rules if @config.rules

        org_name = repo.split("/").first?
        if org_name && (orgs = @config.orgs)
          if org_config = orgs[org_name]?
            return org_config.rules
          end
        end
        return nil
      end

      base = @config.defaults.try(&.rules)
      if name = scope_name
        validate_scope!(name)
        return self.class.merge_rules(base, scopes[name].rules)
      end

      owner = scope_for_repo(repo)
      return base unless owner

      self.class.merge_rules(base, scopes[owner].rules)
    end

    # Returns true if *repo* matches any pattern in *patterns*.
    def excluded?(repo : String, patterns : Array(String)) : Bool
      patterns.any? { |pattern| self.class.matches?(pattern, repo) }
    end

    # Returns true when *pattern* contains glob characters.
    def self.glob?(pattern : String) : Bool
      pattern.includes?('*') || pattern.includes?('?') || pattern.includes?('[')
    end

    # Matches a repo selector against a full repo name.
    #
    # `*` matches any characters including `/`, so `*-api` matches
    # `unurgunite/payment-api`. A selector without `/` also matches
    # against the short repo name.
    def self.matches?(pattern : String, repo : String) : Bool
      pat = pattern.strip
      return false if pat.empty?
      return true if pat == repo
      return true if glob_match?(pat, repo)

      unless pat.includes?("/")
        short = repo.split("/").last
        return true if glob_match?(pat, short)
      end
      false
    end

    # Removes repos matching any pattern in *patterns* (globs supported).
    def self.filter_exclude(repos : Array(String), patterns : Array(String)) : Array(String)
      return repos if patterns.empty?
      repos.reject { |repo| patterns.any? { |pattern| matches?(pattern, repo) } }
    end

    # Parses a `--only` flag value into a set of subsystem names.
    #
    # Returns nil for blank input (meaning: process everything).
    # Raises ArgumentError with a plain-language message for unknown values.
    def self.parse_only(raw : String?) : Set(String)?
      return nil if raw.nil?
      cleaned = raw.strip
      return nil if cleaned.empty?

      parts = cleaned.split(",").map(&.strip.downcase).reject(&.empty?).uniq!
      invalid = parts.reject { |part| VALID_ONLY_VALUES.includes?(part) }
      unless invalid.empty?
        raise ArgumentError.new("Unknown --only value(s): #{invalid.join(", ")}. Valid values: #{VALID_ONLY_VALUES.join(", ")}. Example: --only branch,labels")
      end
      Set(String).new(parts)
    end

    # Merges two rule maps. *override* wins per branch type and per field.
    def self.merge_rules(
      base : Hash(String, BranchRuleConfig)?,
      override : Hash(String, BranchRuleConfig)?,
    ) : Hash(String, BranchRuleConfig)?
      return override if base.nil?
      return base if override.nil?

      merged = {} of String => BranchRuleConfig
      (base.keys + override.keys).uniq.each do |key|
        base_rule = base[key]?
        override_rule = override[key]?
        if base_rule && override_rule
          merged[key] = merge_branch(base_rule, override_rule)
        elsif rule = override_rule || base_rule
          merged[key] = rule
        end
      end
      merged
    end

    # Merges two branch configs. Non-nil *override* fields win.
    #
    # Merge methods (`merge`/`squash`/`rebase`) merge as a group: when
    # the override sets any of them, the other two are cleared instead
    # of inherited, keeping at most one method set to `"only"`.
    def self.merge_branch(base : BranchRuleConfig, override : BranchRuleConfig) : BranchRuleConfig
      merged = BranchRuleConfig.new
      if override.merge || override.squash || override.rebase
        merged.merge = override.merge
        merged.squash = override.squash
        merged.rebase = override.rebase
      else
        merged.merge = base.merge
        merged.squash = base.squash
        merged.rebase = base.rebase
      end
      merged.name = override.name.nil? ? base.name : override.name
      merged.pattern = override.pattern.nil? ? base.pattern : override.pattern
      merged.checks = override.checks.nil? ? base.checks : override.checks
      merged.linear_history = override.linear_history.nil? ? base.linear_history : override.linear_history
      merged.delete_branch = override.delete_branch.nil? ? base.delete_branch : override.delete_branch
      merged
    end

    private def self.glob_match?(pattern : String, str : String) : Bool
      !glob_to_regex(pattern).match(str).nil?
    end

    private def self.glob_to_regex(pattern : String) : Regex
      io = IO::Memory.new
      io << "\\A"
      i = 0
      while i < pattern.size
        char = pattern[i]
        case char
        when '*'
          io << ".*"
        when '?'
          io << "."
        when '['
          closing = pattern.index(']', i)
          if closing
            io << pattern[i..closing]
            i = closing
          else
            io << "\\["
          end
        when '.', '+', '(', ')', '|', '^', '$', '{', '}', '\\'
          io << "\\" << char
        else
          io << char
        end
        i += 1
      end
      io << "\\z"
      Regex.new(io.to_s)
    end
  end
end
