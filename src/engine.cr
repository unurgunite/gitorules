require "./resource"
require "./resources/branch_rules"

module Gitorules
  # Facade over managed resources.
  #
  # Keeps the public CLI surface stable and delegates
  # status, diff and apply operations to resources.
  class Engine
    @branch_rules : Resources::BranchRules

    def initialize(client : GitHubClient, config : Config)
      @branch_rules = Resources::BranchRules.new(client, config)
    end

    def status(repos : Array(String), quiet : Bool = false, io : IO = STDOUT, only : String? = nil)
      @branch_rules.status(repos, quiet, io, only)
    end

    def status_json(repos : Array(String), io : IO = STDOUT, only : String? = nil)
      @branch_rules.status_json(repos, io, only)
    end

    def diff(repos : Array(String), quiet : Bool = false, io : IO = STDOUT, only : String? = nil, verbose : Bool = false)
      @branch_rules.diff(repos, quiet, io, only, verbose)
    end

    def diff_json(repos : Array(String), io : IO = STDOUT, only : String? = nil)
      @branch_rules.diff_json(repos, io, only)
    end

    def apply(repos : Array(String), dry_run : Bool = false, quiet : Bool = false, io : IO = STDOUT, only : String? = nil, verbose : Bool = false)
      @branch_rules.apply(repos, dry_run, quiet, io, only, verbose)
    end

    def apply_json(repos : Array(String), dry_run : Bool = false, io : IO = STDOUT, only : String? = nil)
      @branch_rules.apply_json(repos, dry_run, io, only)
    end
  end
end
