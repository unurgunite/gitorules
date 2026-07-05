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
  end
end
