require "colorize"

module Gitorules
  # Evaluates and applies ruleset configuration across repositories.
  #
  # Compares current GitHub rulesets against the desired state from
  # `.gitorules.yml` and reports discrepancies or applies changes.
  class Engine
    MASTER_NAMES = {"Master - merge commits only", "master"}
    RELEASE_NAME = "Release branches - squash only"

    @client : GitHubClient
    @config : Config

    # @param client [GitHubClient] Authenticated API client
    # @param config [Config] Parsed configuration
    def initialize(@client : GitHubClient, @config : Config)
    end

    # Prints a status table for all given repositories.
    #
    # For each repo: checks master ruleset (merge method + checks)
    # and release ruleset (squash method). Colorized output.
    #
    # @param repos [Array(String)] Full repository names
    # @param io [IO] Output stream (default: STDOUT)
    def status(repos : Array(String), io : IO = STDOUT)
      io.puts "%-40s %-14s %-14s %s" % ["Repository", "Master", "Release", "Check"]
      io.puts "─" * 80

      repos.each do |repo|
        master_ok = false
        release_ok = false
        check_ok = false

        begin
          rulesets = @client.list_rulesets(repo)

          if master_rs = rulesets.find(&.name.in?(MASTER_NAMES))
            if rs_id = master_rs.id
              full = @client.get_ruleset(repo, rs_id)
              if pr_rule = full.rules.find { |r| r.type == "pull_request" }
                if params = pr_rule.parameters
                  if methods = params["allowed_merge_methods"]?.try(&.as_a)
                    master_ok = methods.any? { |m| m.to_s == "merge" }
                  end
                end
              end
              check_ok = full.rules.any? { |r| r.type == "required_status_checks" }
            end
          end

          if release_rs = rulesets.find { |rs| rs.name == RELEASE_NAME }
            if rs_id = release_rs.id
              full = @client.get_ruleset(repo, rs_id)
              if pr_rule = full.rules.find { |r| r.type == "pull_request" }
                if params = pr_rule.parameters
                  if methods = params["allowed_merge_methods"]?.try(&.as_a)
                    release_ok = methods.any? { |m| m.to_s == "squash" }
                  end
                end
              end
            end
          end
        rescue ex
          io.puts "%s  %s" % [repo, ex.message]
          next
        end

        master_s = master_ok ? "✓ merge".colorize.green : "✗ MISSING".colorize.red
        release_s = release_ok ? "✓ squash".colorize.green : "✗ MISSING".colorize.red
        check_s = check_ok ? "✓ active".colorize.green : "✗ missing".colorize.yellow

        io.puts "%-40s %s" % [repo, "#{master_s}  #{release_s}  #{check_s}"]
      end
    end

    # Applies desired ruleset configuration to repositories.
    #
    # Creates or updates master and release rulesets based on config.
    # In dry-run mode prints intended actions without API calls.
    #
    # @param repos [Array(String)] Full repository names
    # @param dry_run [Bool] Preview only (default: false)
    def apply(repos : Array(String), dry_run : Bool = false, io : IO = STDOUT)
      repos.each do |repo|
        apply_repo(repo, dry_run, io)
      end
    end

    private def apply_repo(repo : String, dry_run : Bool, io : IO)
      existing = @client.list_rulesets(repo)

      if master_config = @config.rules.try(&.["default_branch"]?)
        wanted = build_master_ruleset(master_config)
        found = existing.find(&.name.in?(MASTER_NAMES))
        apply_ruleset(repo, found, wanted, dry_run, io)
      end

      if release_config = @config.rules.try(&.["release"]?)
        wanted = build_release_ruleset(release_config)
        found = existing.find { |rs| rs.name == RELEASE_NAME }
        apply_ruleset(repo, found, wanted, dry_run, io)
      end
    end

    private def build_master_ruleset(config : BranchRuleConfig) : Ruleset
      refs = ["refs/heads/master"]
      build_ruleset(MASTER_NAMES.first, config, refs)
    end

    private def build_release_ruleset(config : BranchRuleConfig) : Ruleset
      pattern = config.pattern || "v*"
      refs = ["refs/heads/#{pattern}"]
      build_ruleset(RELEASE_NAME, config, refs)
    end

    private def build_ruleset(name : String, config : BranchRuleConfig, ref_include : Array(String)) : Ruleset
      rules = [] of Rule
      rules << Rule.new("deletion")
      rules << Rule.new("non_fast_forward")
      rules << Rule.new("pull_request", merge_method_params(config.merge_method))

      if checks = config.checks
        rules << Rule.new("required_status_checks", required_status_checks_params(checks))
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

    private def apply_ruleset(repo : String, existing : Ruleset?, wanted : Ruleset, dry_run : Bool, io : IO)
      if dry_run
        if existing && existing.id
          io.puts "#{repo}: Would update ruleset '#{wanted.name}' (ID #{existing.id})"
        else
          io.puts "#{repo}: Would create ruleset '#{wanted.name}'"
        end
        return
      end

      if existing && (id = existing.id)
        @client.update_ruleset(repo, id, wanted)
        io.puts "#{repo}: Updated ruleset '#{wanted.name}'"
      else
        @client.create_ruleset(repo, wanted)
        io.puts "#{repo}: Created ruleset '#{wanted.name}'"
      end
    end
  end
end
