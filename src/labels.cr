require "json"
require "yaml"

module Gitorules
  # Sync mode for labels not present in config.
  #
  # Modes: `prune` deletes orphans, `warn` reports them without
  # deleting, `ignore` skips them entirely. Default is `warn`,
  # which never deletes.
  module LabelsSync
    PRUNE   = "prune"
    WARN    = "warn"
    IGNORE  = "ignore"
    DEFAULT = WARN

    # Resolves the effective sync mode for a config.
    #
    # Raises on unknown values so misconfiguration fails fast.
    #
    # @param config [Config] Parsed configuration
    # @return [String] Effective mode (`prune`, `warn`, or `ignore`)
    # @raise [RuntimeError] On unknown `labels_sync` value
    def self.mode(config : Config) : String
      raw = config.labels_sync.try(&.strip.downcase) || DEFAULT
      unless raw == PRUNE || raw == WARN || raw == IGNORE
        raise "labels_sync: expected prune|warn|ignore, got #{config.labels_sync.inspect}"
      end
      raw
    end

    # Validates the sync mode eagerly (used by CLI before dispatch).
    #
    # @param config [Config] Parsed configuration
    # @raise [RuntimeError] On unknown `labels_sync` value
    def self.validate!(config : Config) : Nil
      mode(config)
    end
  end

  # Computed change for a single label.
  #
  # Actions: `create`, `update`, `orphan`, `unchanged`.
  record LabelChange, action : String, name : String, changes : Array(String)

  # Synchronizes GitHub issue labels for a repository.
  #
  # Reads wanted labels from `Config#labels`, compares against the
  # Labels API, and creates/updates (and optionally deletes) labels.
  # The default sync mode (`warn`) never deletes.
  class LabelResource
    # Value used in JSON entries to identify this resource.
    RESOURCE = "labels"

    def initialize(@client : GitHubClient, @config : Config)
    end

    # Wanted labels from config (empty when not configured).
    def wanted : Array(Label)
      @config.labels || [] of Label
    end

    # True when the config declares any labels.
    def configured? : Bool
      !wanted.empty?
    end

    # Effective sync mode (`prune`, `warn`, or `ignore`).
    def sync_mode : String
      LabelsSync.mode(@config)
    end

    # Computes pending changes without performing any writes.
    #
    # @param repo [String] Full repository name (owner/name)
    # @return [Array(LabelChange)] One entry per wanted/orphan label
    def diff_entries(repo : String) : Array(LabelChange)
      wants = wanted
      return [] of LabelChange if wants.empty?
      build_entries(wants, @client.list_labels(repo), sync_mode)
    end

    # Builds entries from wanted vs actual labels (pure, no I/O).
    #
    # @param wants [Array(Label)] Desired labels from config
    # @param actual [Array(Label)] Current labels from the API
    # @param mode [String] Sync mode (`prune`, `warn`, or `ignore`)
    # @return [Array(LabelChange)] Computed entries
    def build_entries(wants : Array(Label), actual : Array(Label), mode : String) : Array(LabelChange)
      entries = [] of LabelChange
      by_actual = {} of String => Label
      actual.each { |l| by_actual[l.name] = l }
      want_names = wants.map(&.name)

      wants.each do |w|
        if have = by_actual[w.name]?
          changes = label_changes(w, have)
          entries << LabelChange.new(action: changes.empty? ? "unchanged" : "update", name: w.name, changes: changes)
        else
          entries << LabelChange.new(action: "create", name: w.name, changes: ["color: #{w.norm_color}", "description: #{w.norm_description.inspect}"])
        end
      end

      return entries if mode == LabelsSync::IGNORE

      actual.each do |a|
        next if want_names.includes?(a.name)
        if mode == LabelsSync::PRUNE
          entries << LabelChange.new(action: "orphan", name: a.name, changes: ["delete on prune"])
        else
          entries << LabelChange.new(action: "orphan", name: a.name, changes: ["orphan (warn only, kept)"])
        end
      end

      entries
    end

    # Applies label changes. Dry-run performs zero writes.
    #
    # @param repo [String] Full repository name (owner/name)
    # @param dry_run [Bool] Preview only, perform no writes
    # @param quiet [Bool] Suppress per-label output
    # @param io [IO] Output stream
    # @param prefix [String] Progress prefix (e.g. `[1/2] `)
    def apply(repo : String, dry_run : Bool = false, quiet : Bool = false, io : IO = STDOUT, prefix : String = "")
      wants = wanted
      return if wants.empty?
      mode = sync_mode
      actual = @client.list_labels(repo)
      entries = build_entries(wants, actual, mode)
      by_want = {} of String => Label
      wants.each { |l| by_want[l.name] = l }

      entries.each do |entry|
        case entry.action
        when "create"
          want = by_want[entry.name]
          if dry_run
            io.puts "#{prefix}#{repo}: Would create label '#{entry.name}'" unless quiet
          else
            @client.create_label(repo, want)
            io.puts "#{prefix}#{repo}: Created label '#{entry.name}'" unless quiet
          end
        when "update"
          want = by_want[entry.name]
          if dry_run
            io.puts "#{prefix}#{repo}: Would update label '#{entry.name}' (#{entry.changes.join(", ")})" unless quiet
          else
            @client.update_label(repo, entry.name, want)
            io.puts "#{prefix}#{repo}: Updated label '#{entry.name}'" unless quiet
          end
        when "orphan"
          if mode == LabelsSync::PRUNE
            if dry_run
              io.puts "#{prefix}#{repo}: Would delete label '#{entry.name}' (prune)" unless quiet
            else
              @client.delete_label(repo, entry.name)
              io.puts "#{prefix}#{repo}: Deleted label '#{entry.name}'" unless quiet
            end
          else
            io.puts "#{prefix}#{repo}: Orphan label '#{entry.name}' (warn only, kept)" unless quiet
          end
        end
      end
    end

    # Prints human-readable label status for a repository.
    #
    # @param repo [String] Full repository name (owner/name)
    # @param quiet [Bool] Suppress output
    # @param io [IO] Output stream
    # @param prefix [String] Progress prefix (e.g. `[1/2] `)
    def status(repo : String, quiet : Bool = false, io : IO = STDOUT, prefix : String = "")
      return unless configured?
      entries = diff_entries(repo)
      return if quiet
      pending = entries.reject(&.action.==("unchanged"))
      if pending.empty?
        io.puts "#{prefix}#{repo}: labels up to date (#{entries.size})"
      else
        summary = pending.map { |e| "#{e.action} #{e.name}" }.join(", ")
        io.puts "#{prefix}#{repo}: labels: #{summary}"
      end
    end

    # Prints pending label changes without applying them.
    #
    # @param repo [String] Full repository name (owner/name)
    # @param quiet [Bool] Suppress output
    # @param io [IO] Output stream
    # @param prefix [String] Progress prefix (e.g. `[1/2] `)
    def diff(repo : String, quiet : Bool = false, io : IO = STDOUT, prefix : String = "")
      return unless configured?
      entries = diff_entries(repo)
      return if quiet
      io.puts "#{prefix}=== #{repo} labels (#{sync_mode}) ==="
      entries.each do |e|
        case e.action
        when "create"
          io.puts "  #{green("+ Create label '#{e.name}'", io)}"
        when "update"
          io.puts "  #{yellow("~ Update label '#{e.name}': #{e.changes.join(", ")}", io)}"
        when "orphan"
          if sync_mode == LabelsSync::PRUNE
            io.puts "  #{red("- Delete label '#{e.name}' (prune)", io)}"
          else
            io.puts "  #{red("- Orphan label '#{e.name}' (warn only, kept)", io)}"
          end
        else
          io.puts "  #{dim("  Label '#{e.name}': no changes", io)}"
        end
      end
    end

    # Computes entries for apply JSON output without performing writes.
    #
    # Mirrors the ruleset apply JSON behavior, which never writes and
    # only reports pending actions.
    #
    # @param repo [String] Full repository name (owner/name)
    # @return [Array(LabelChange)] Pending entries
    def apply_preview(repo : String) : Array(LabelChange)
      diff_entries(repo)
    end

    # Writes one label entry in `{repo, resource, action, changes[]}` shape.
    #
    # @param json [JSON::Builder] Open builder (object or array context)
    # @param repo [String] Full repository name (owner/name)
    # @param entry [LabelChange] Entry to serialize
    # @param dry_run [Bool] Include `dry_run: true` marker
    def write_json_entry(json : JSON::Builder, repo : String, entry : LabelChange, dry_run : Bool = false)
      json.object do
        json.field "repo", repo
        json.field "resource", RESOURCE
        json.field "action", entry.action
        json.field "name", entry.name
        json.field "changes", entry.changes
        json.field "dry_run", true if dry_run
      end
    end

    # Compares a single wanted vs actual label.
    private def label_changes(want : Label, have : Label) : Array(String)
      changes = [] of String
      if want.norm_color != have.norm_color
        changes << "color: #{have.norm_color} → #{want.norm_color}"
      end
      if want.norm_description != have.norm_description
        changes << "description: #{have.norm_description.inspect} → #{want.norm_description.inspect}"
      end
      changes
    end

    private def colorize?(io : IO) : Bool
      io.responds_to?(:tty?) && io.tty?
    end

    private def green(text : String, io : IO) : String
      colorize?(io) ? text.colorize.green.to_s : text
    end

    private def red(text : String, io : IO) : String
      colorize?(io) ? text.colorize.red.to_s : text
    end

    private def yellow(text : String, io : IO) : String
      colorize?(io) ? text.colorize.yellow.to_s : text
    end

    private def dim(text : String, io : IO) : String
      colorize?(io) ? text.colorize.dim.to_s : text
    end
  end
end
