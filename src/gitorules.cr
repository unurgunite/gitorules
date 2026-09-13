require "./types"
require "./concurrent"
require "./json_entry"
require "./scope"
require "./labels"
require "./github"
require "./config"
require "./workflows"
require "./resource"
require "./resources/branch_rules"
require "./engine"
require "./init"
require "./lint"
require "./cli"

module Gitorules
  VERSION = "0.2.0"
end

unless ENV["CRYSTAL_SPEC"]?
  exit(Gitorules::CLI.run)
end
