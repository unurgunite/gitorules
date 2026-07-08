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
      help_text = ""

      OptionParser.parse(args) do |parser|
        help_text = parser.to_s
        parser.banner = "Usage: gitorules <status|apply|diff|init> [options]\n\nCommands:\n"

        parser.on("status", "Show ruleset status for repositories") do
          options.mode = "status"
        end

        parser.on("apply", "Apply ruleset configuration from .gitorules.yml") do
          options.mode = "apply"
        end

        parser.on("diff", "Show pending changes without applying") do
          options.mode = "diff"
        end

        parser.on("init", "Generate .gitorules.yml from existing rulesets") do
          options.mode = "init"
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

        parser.on("--org ORG", "GitHub organization name (for init)") do |v|
          options.org = v
        end

        parser.on("--json", "Machine-readable JSON output") do
          options.json = true
        end

        parser.on("--quiet", "Suppress all output except errors") do
          options.quiet = true
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
      rescue ex
        STDERR.puts "Error loading config: #{ex.message}"
        raise ExitSignal.new(2)
      end

      engine = Engine.new(client, loader.config)

      repos = if repo = options.repo
                [repo]
              else
                loader.repo_names
              end

      execute_command(engine, repos, options, STDOUT, input_io)
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

    private def self.execute_command(engine : Engine, repos : Array(String), options : Options, io : IO, input_io : IO = STDIN) : Int32
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
        cmd_diff(engine, repos, options, io)
      else
        STDERR.puts "gitorules: unknown subcommand '#{options.mode}'"
        2
      end
    end

    private def self.cmd_status(engine : Engine, repos : Array(String), options : Options, io : IO) : Int32
      if options.json?
        engine.status_json(repos, io)
      else
        engine.status(repos, quiet: options.quiet?, io: io)
      end
      0
    end

    private def self.cmd_apply(engine : Engine, repos : Array(String), options : Options, io : IO, input_io : IO) : Int32
      if options.diff?
        if options.json?
          engine.diff_json(repos, io)
        else
          engine.diff(repos, io: io)
        end
        return 0
      end

      if options.json?
        engine.apply_json(repos, dry_run: options.dry_run?, io: io)
        return 0
      end

      diff_io = IO::Memory.new
      engine.diff(repos, io: diff_io)
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

        engine.apply(repos, dry_run: options.dry_run?, quiet: options.quiet?, io: io)
        1
      else
        io.puts "no changes" unless options.quiet?
        0
      end
    end

    private def self.cmd_diff(engine : Engine, repos : Array(String), options : Options, io : IO) : Int32
      if options.json?
        engine.diff_json(repos, io)
        return 0
      end

      diff_io = IO::Memory.new
      engine.diff(repos, io: diff_io)
      diff_text = diff_io.to_s
      io.print diff_text unless options.quiet?

      diff_has_changes?(diff_text) ? 1 : 0
    end

    private def self.diff_has_changes?(diff_text : String) : Bool
      diff_text.lines.any? { |line|
        stripped = line.strip
        stripped.starts_with?("+") || stripped.starts_with?("-") || stripped.starts_with?("~")
      }
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
