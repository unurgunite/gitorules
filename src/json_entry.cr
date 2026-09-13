require "json"

module Gitorules
  # Valid actions for unified JSON entries.
  #
  # Every JSON output (status, diff, apply) exposes per-resource
  # entries with `resource`, `action` and `changes` fields using one
  # shared vocabulary so CI consumers can parse all commands alike.
  VALID_JSON_ACTIONS = %w[create update unchanged orphan skip error]

  # A single unified JSON entry.
  #
  # `repo` is the full repository name (owner/name), `resource` is the
  # ruleset display name (or empty for repo-level errors), `action` is
  # one of VALID_JSON_ACTIONS and `changes` lists human-readable
  # differences (empty when there is nothing to report).
  struct JsonEntry
    include JSON::Serializable

    property repo : String
    property resource : String
    property action : String
    property changes : Array(String)
    property error : String?

    def initialize(@repo : String, @resource : String, @action : String, @changes : Array(String) = [] of String, @error : String? = nil)
    end

    # Returns true when *action* is part of the unified contract.
    def self.valid_action?(action : String) : Bool
      VALID_JSON_ACTIONS.includes?(action)
    end
  end
end
