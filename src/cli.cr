require "option_parser"

module Gitorules
  class CLI
    # Signals a controlled exit with a specific exit code.
    #
    # Used inside OptionParser blocks where `return` is forbidden,
    # to abort normal flow and return an exit code to the caller.
    #
    # Exit codes:
    #   0 - No changes needed (everything up-to-date)
    #   1 - Changes detected or applied
    #   2 - Error (config, auth, API failure)
    class ExitSignal < Exception
      getter code : Int32

      def initialize(@code : Int32)
      end
    end

    # Entry point for the CLI.
    #
    # Parses command-line arguments, loads config, and dispatches
    # to the appropriate engine command. Returns a shell exit code.
    #
    # @param args [Array(String)] Command-line arguments (default: ARGV)
    # @param input_io [IO] Input stream for prompts (default: STDIN)
    # @return [Int32] Exit code (0 = no changes, 1 = changes detected/applied, 2 = error)
    def self.run(args : Array(String) = ARGV, input_io : IO = STDIN) : Int32
      execute(args, input_io)
    rescue ex : ExitSignal
      ex.code
    end

    # Internal execution logic.
    #
    # Separated from `#run` so that ExitSignal raised in OptionParser
    # blocks can be caught without affecting the normal return path.
    #
    # @param args [Array(String)] Command-line arguments
    # @param input_io [IO] Input stream for prompts (default: STDIN)
    # @return [Int32] Exit code
    # @raise [ExitSignal] On --version, --help, or any error condition
    private def self.execute(args : Array(String), input_io : IO = STDIN)
      options = Options.new
      config_path = ".gitorules.yml"
      in_place = false
      help_text = ""

      normalized = normalize_scope_verify(args)

      OptionParser.parse(normalized) do |parser|
        help_text = parser.to_s
        parser.banner = "Usage: gitorules <status|apply|diff|init|lint|migrate|verify> [options]\n\nCommands:\n"

        parser.on("status", "Show branch status for repositories") do
          options.mode = "status"
        end

        parser.on("apply", "Apply branch configuration from .gitorules.yml") do
          options.mode = "apply"
        end

        parser.on("diff", "Show pending changes without applying") do
          options.mode = "diff"
        end

        parser.on("init", "Generate .gitorules.yml from existing branch rules") do
          options.mode = "init"
        end

        parser.on("lint", "Validate config file schema and values") do
          options.mode = "lint"
        end

        parser.on("migrate", "Convert legacy config to defaults/scopes shape") do
          options.mode = "migrate"
        end

        parser.on("verify", "Verify required checks are produced by workflows") do
          options.mode = "verify"
        end

        parser.separator "\nOptions:\n"

        parser.on("--dry-run", "Preview apply changes without making them") do
          options.dry_run = true
        end

        parser.on("--diff", "Show pending changes (same as diff command)") do
          options.diff = true
        end

        parser.on("--repo REPO", "Target a single repository (owner/name)") do |v|
          options.repo = v
        end

        parser.on("--scope NAME", "Only process repositories in this scope") do |v|
          options.scope = v
        end

        parser.on("--only LIST", "Only process subsystems: branch,labels,workflows (comma-separated)") do |v|
          options.only = v
        end

        parser.on("--exclude REPO", "Exclude repository (owner/name, repeatable)") do |v|
          v.split(",").each do |part|
            repo = part.strip
            options.exclude << repo unless repo.empty?
          end
        end

        parser.on("--verbose", "Show detailed output") do
          options.verbose = true
        end
        parser.on("--org ORG", "GitHub organization name (for init)") do |v|
          options.org = v
        end

        parser.on("--json", "Machine-readable JSON output") do
          options.json = true
        end

        parser.on("--quiet", "Suppress all output except errors") do
          options.quiet = true
        end

        parser.on("--verbose", "Show unchanged workflows and detailed output") do
          options.verbose = true
        end

        parser.on("--yes", "Skip confirmation prompt and apply immediately") do
          options.yes = true
        end

        parser.on("--token TOKEN", "GitHub personal access token") do |v|
          options.token = v
        end

        parser.on("--app-id ID", "GitHub App ID (for GitHub App auth)") do |v|
          options.app_id = v
        end

        parser.on("--private-key PEM", "GitHub App private key (PEM content)") do |v|
          options.private_key = v
        end

        parser.on("--private-key-path PATH", "Path to GitHub App private key PEM file") do |v|
          options.private_key = File.read(v)
        rescue ex
          STDERR.puts "Error reading private key: #{ex.message}"
          raise ExitSignal.new(2)
        end

        parser.on("--installation-id ID", "GitHub App installation ID") do |v|
          options.installation_id = v
        end

        parser.on("--config PATH", "Path to config file (default: .gitorules.yml)") do |v|
          config_path = v
        end

        parser.on("--in-place", "Overwrite config file in place (migrate only)") do
          in_place = true
        end

        parser.on("--version", "Show version") do
          puts "gitorules v#{VERSION}"
          raise ExitSignal.new(0)
        end

        parser.on("-h", "--help", "Show help") do
          puts parser
          raise ExitSignal.new(0)
        end
      end

      if options.mode.empty?
        puts help_text
        return 0
      end

      # Offline commands need no auth token.
      if options.mode == "lint"
        return Linter.lint_file(config_path)
      end

      if options.mode == "migrate"
        return Migrator.migrate_file(config_path, in_place)
      end

      if options.mode == "verify"
        return Verifier.verify_file(config_path, options.scope, options.json?)
      end

      if in_place
        STDERR.puts "Warning: --in-place has no effect on '#{options.mode}' command"
      end

      run_with_options(options, config_path, input_io)
    end

    private def self.run_with_options(options : Options, config_path : String, input_io : IO) : Int32
      client = build_client(options)

      # Handle init separately — no config needed
      if options.mode == "init"
        return handle_init(options, client)
      end

      token = client.token
      unless token
        STDERR.puts "Error: no auth token available"
        raise ExitSignal.new(2)
      end

      begin
        loader = ConfigLoader.new(config_path, token)
      rescue ex : UnknownScopeError
        STDERR.puts "Error: #{ex.message}"
        raise ExitSignal.new(2)
      rescue ex
        STDERR.puts "Error loading config: #{ex.message}"
        raise ExitSignal.new(2)
      end

      begin
        LabelsSync.validate!(loader.config)
      rescue ex
        STDERR.puts "Error loading config: #{ex.message}"
        raise ExitSignal.new(2)
      end

      only_set = parse_only_option!(options.only)

      if scope_name = options.scope
        resolver = ScopeResolver.new(loader.config)
        unless resolver.has_scope?(scope_name)
          STDERR.puts "Error: unknown scope '#{scope_name}'. Available scopes: #{resolver.scope_names.join(", ")}. Check the `scopes:` section in your config file or run without --scope to use all scopes."
          raise ExitSignal.new(2)
        end
      end

      if nothing_to_do?(only_set)
        unless options.quiet?
          STDOUT.puts "Skipped branch, labels and workflows (--only #{options.only}). Nothing to do."
        end
        return 0
      end

      engine = Engine.new(client, loader.config)

      repos, scope_groups = resolve_repos(loader, options)

      execute_command(engine, repos, options, STDOUT, input_io, scope_groups)
    end

    # True when an `--only` filter selects none of the known subsystems.
    #
    # Valid values are `branch`, `labels` and `workflows`. A validated
    # set always contains at least one of them, so this is only a safety
    # net for empty or future values.
    private def self.nothing_to_do?(only_set : Set(String)?) : Bool
      return false unless only_set
      !only_set.includes?("branch") && !only_set.includes?("labels") && !only_set.includes?("workflows")
    end

    private def self.build_client(options : Options) : GitHubClient
      app_id = options.app_id || ENV["GITHUB_APP_ID"]?
      private_key = options.private_key || ENV["GITHUB_APP_PRIVATE_KEY"]?
      installation_id = options.installation_id || ENV["GITHUB_APP_INSTALLATION_ID"]?

      if app_id && private_key && installation_id
        return GitHubClient.new(app_id, private_key, installation_id)
      end

      token = options.token || ENV["GITHUB_TOKEN"]?
      if token
        return GitHubClient.new(token)
      end

      STDERR.puts "Error: no auth method configured. Use --token / GITHUB_TOKEN for PAT, or --app-id + --private-key + --installation-id / GITHUB_APP_* env for GitHub App"
      STDERR.puts "Create a token: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens"
      raise ExitSignal.new(2)
    end

    # Resolves target repositories, honoring --repo, --scope and --exclude.
    #
    # `--repo` wins as a debug override. With named scopes configured,
    # returns per-scope groups for grouped output plus a deduped flat list.
    private def self.resolve_repos(loader : ConfigLoader, options : Options) : Tuple(Array(String), Hash(String, Array(String))?)
      if repo = options.repo
        return {[repo], nil}
      end

      if loader.config.scopes
        begin
          groups = loader.scope_groups(options.scope, options.exclude)
        rescue ex : UnknownScopeError
          STDERR.puts "Error: #{ex.message}"
          raise ExitSignal.new(2)
        rescue ex
          STDERR.puts "Error resolving scopes: #{ex.message}"
          raise ExitSignal.new(2)
        end
        flat = [] of String
        groups.each_value do |scope_repos|
          scope_repos.each { |name| flat << name unless flat.includes?(name) }
        end
        return {flat, groups}
      end

      begin
        repos = loader.repo_names
      rescue ex
        STDERR.puts "Error loading config: #{ex.message}"
        raise ExitSignal.new(2)
      end
      repos = ScopeResolver.filter_exclude(repos, options.exclude) unless options.exclude.empty?
      {repos, nil}
    end

    # Parses `--only`, failing fast with exit code 2 on unknown values.
    private def self.parse_only_option!(raw : String?) : Set(String)?
      ScopeResolver.parse_only(raw)
    rescue ex : ArgumentError
      STDERR.puts "Error: #{ex.message}"
      raise ExitSignal.new(2)
    end

    # Normalizes `scope verify` to `verify`.
    #
    # Accepts both `gitorules verify` and `gitorules scope verify`
    # spellings; extra flags are preserved in order.
    private def self.normalize_scope_verify(args : Array(String)) : Array(String)
      if args.size >= 2 && args[0] == "scope" && args[1] == "verify"
        return ["verify"] + args[2..]
      end
      args
    end

    private def self.execute_command(engine : Engine, repos : Array(String), options : Options, io : IO, input_io : IO = STDIN, groups : Hash(String, Array(String))? = nil) : Int32
      if options.dry_run? && options.mode != "apply"
        STDERR.puts "Warning: --dry-run has no effect on '#{options.mode}' command"
      end
      if options.diff? && options.mode != "apply"
        STDERR.puts "Warning: --diff has no effect on '#{options.mode}' command"
      end

      case options.mode
      when "status"
        cmd_status(engine, repos, options, io)
      when "apply"
        cmd_apply(engine, repos, options, io, input_io)
      when "diff"
        cmd_diff(engine, repos, options, io, groups)
      else
        STDERR.puts "gitorules: unknown subcommand '#{options.mode}'"
        2
      end
    end

    private def self.cmd_status(engine : Engine, repos : Array(String), options : Options, io : IO) : Int32
      if options.json?
        engine.status_json(repos, io, options.only)
      else
        engine.status(repos, quiet: options.quiet?, io: io, only: options.only)
      end
      0
    end

    private def self.cmd_apply(engine : Engine, repos : Array(String), options : Options, io : IO, input_io : IO) : Int32
      if options.diff?
        if options.json?
          engine.diff_json(repos, io, options.only)
        else
          engine.diff(repos, verbose: options.verbose?, io: io, only: options.only)
        end
        return 0
      end

      if options.json?
        engine.apply_json(repos, dry_run: options.dry_run?, io: io, only: options.only)
        return 0
      end

      diff_io = IO::Memory.new
      engine.diff(repos, verbose: options.verbose?, io: diff_io, only: options.only)
      diff_text = diff_io.to_s
      io.print diff_text unless options.quiet?

      if diff_has_changes?(diff_text)
        unless options.yes?
          STDERR.print "Apply these changes? [y/N] "
          answer = input_io.gets
          unless answer && answer.strip.downcase == "y"
            return 1
          end
        end

        engine.apply(repos, dry_run: options.dry_run?, quiet: options.quiet?, verbose: options.verbose?, io: io, only: options.only)
        1
      else
        io.puts "no changes" unless options.quiet?
        0
      end
    rescue ex : WorkflowError
      STDERR.puts "Error: #{ex.message}"
      2
    end

    private def self.cmd_diff(engine : Engine, repos : Array(String), options : Options, io : IO, groups : Hash(String, Array(String))? = nil) : Int32
      if options.json?
        engine.diff_json(repos, io, options.only)
        return 0
      end

      if groups && options.repo.nil?
        return cmd_diff_scoped(engine, groups, options, io)
      end

      diff_io = IO::Memory.new
      engine.diff(repos, verbose: options.verbose?, io: diff_io, only: options.only)
      diff_text = diff_io.to_s
      io.print diff_text unless options.quiet?

      diff_has_changes?(diff_text) ? 1 : 0
    rescue ex : WorkflowError
      STDERR.puts "Error: #{ex.message}"
      2
    end

    # Scoped diff: grouped by scope with summary counters.
    #
    # Headers and counters always print (unless --quiet). Per-repo
    # details print only with --verbose to keep scoped output concise.
    private def self.cmd_diff_scoped(engine : Engine, groups : Hash(String, Array(String)), options : Options, io : IO) : Int32
      total_repos = groups.sum { |_, scope_repos| scope_repos.size }
      scopes_with_changes = groups.count { |scope_name, scope_repos| diff_one_scope(engine, scope_name, scope_repos, options, io) }

      print_diff_totals(io, options, total_repos, groups.size, scopes_with_changes)

      scopes_with_changes > 0 ? 1 : 0
    end

    private def self.diff_one_scope(engine : Engine, scope_name : String, scope_repos : Array(String), options : Options, io : IO) : Bool
      if scope_repos.empty?
        io.puts "Scope: #{scope_name} (0 repos)" unless options.quiet?
        return false
      end

      repo_word = scope_repos.size == 1 ? "repo" : "repos"
      io.puts "Scope: #{scope_name} (#{scope_repos.size} #{repo_word})" unless options.quiet?

      diff_io = IO::Memory.new
      engine.diff(scope_repos, io: diff_io, only: options.only)
      diff_text = diff_io.to_s
      has_changes = diff_has_changes?(diff_text)

      print_scope_result(io, options, diff_text, scope_repos.size, repo_word, has_changes)
      has_changes
    end

    private def self.print_scope_result(io : IO, options : Options, diff_text : String, repo_count : Int32, repo_word : String, has_changes : Bool)
      if options.verbose?
        io.print diff_text unless options.quiet?
        return
      end

      summary = diff_text.lines.last? || "Done: #{repo_count} repos processed"
      io.puts summary.strip unless options.quiet?
      return if options.quiet?

      if has_changes
        io.puts "  (#{repo_count} #{repo_word}, changes detected - use --verbose for details)"
      else
        io.puts "  (no changes)"
      end
    end

    private def self.print_diff_totals(io : IO, options : Options, total_repos : Int32, scope_count : Int32, scopes_with_changes : Int32)
      return if options.quiet?

      total_word = total_repos == 1 ? "repo" : "repos"
      scope_word = scope_count == 1 ? "scope" : "scopes"
      io.puts "Total: #{total_repos} #{total_word} in #{scope_count} #{scope_word}, #{scopes_with_changes} with changes"
    end

    private def self.diff_has_changes?(diff_text : String) : Bool
      diff_text.lines.any? do |line|
        stripped = line.strip
        stripped.starts_with?("+") || stripped.starts_with?("-") || stripped.starts_with?("~")
      end
    end

    private def self.handle_init(options : Options, client : GitHubClient) : Int32
      repos = if repo = options.repo
                [repo]
              elsif org = options.org
                begin
                  client.list_repos(org).map { |name| "#{org}/#{name}" }
                rescue ex
                  STDERR.puts "Error listing repositories for org '#{org}': #{ex.message}"
                  raise ExitSignal.new(2)
                end
              else
                STDERR.puts "Error: --repo or --org required for init"
                raise ExitSignal.new(2)
              end

      if repos.empty?
        STDERR.puts "Error: no repositories found"
        raise ExitSignal.new(2)
      end

      generator = ConfigGenerator.new(client)
      generator.generate(repos)
      0
    end
  end
end
