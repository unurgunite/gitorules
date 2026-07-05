require "option_parser"

module Gitorules
  class CLI
    # Signals a controlled exit with a specific exit code.
    #
    # Used inside OptionParser blocks where `return` is forbidden,
    # to abort normal flow and return an exit code to the caller.
    class ExitSignal < Exception
      # Exit code (0 = success, 1 = error)
      getter code : Int32

      # @param code [Int32] Exit code to return to the shell
      def initialize(@code : Int32)
      end
    end

    # Entry point for the CLI.
    #
    # Parses command-line arguments, loads config, and dispatches
    # to the appropriate engine command. Returns a shell exit code.
    #
    # @param args [Array(String)] Command-line arguments (default: ARGV)
    # @return [Int32] Exit code (0 = success, 1 = error)
    def self.run(args : Array(String) = ARGV) : Int32
      execute(args)
    rescue ex : ExitSignal
      ex.code
    end

    # Internal execution logic.
    #
    # Separated from `#run` so that ExitSignal raised in OptionParser
    # blocks can be caught without affecting the normal return path.
    #
    # @param args [Array(String)] Command-line arguments
    # @return [Int32] Exit code
    # @raise [ExitSignal] On --version, --help, or any error condition
    private def self.execute(args : Array(String))
      options = Options.new
      config_path = ".gitorules.yml"

      OptionParser.parse(args) do |parser|
        parser.banner = "Usage: gitorules <status|apply> [options]\n\nCommands:\n"

        parser.on("status", "Show ruleset status for repositories") do
          options.mode = "status"
        end

        parser.on("apply", "Apply ruleset configuration from .gitorules.yml") do
          options.mode = "apply"
        end

        parser.separator "\nOptions:\n"

        parser.on("--dry-run", "Preview apply changes without making them") do
          options.dry_run = true
        end

        parser.on("--repo REPO", "Target a single repository (owner/name)") do |v|
          options.repo = v
        end

        parser.on("--token TOKEN", "GitHub personal access token") do |v|
          options.token = v
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

      token = options.token || ENV["GITHUB_TOKEN"]?
      unless token
        STDERR.puts "Error: GITHUB_TOKEN not set. Use --token or set GITHUB_TOKEN env"
        raise ExitSignal.new(1)
      end

      begin
        loader = ConfigLoader.new(config_path, token)
      rescue ex
        STDERR.puts "Error loading config: #{ex.message}"
        raise ExitSignal.new(1)
      end

      client = GitHubClient.new(token)
      engine = Engine.new(client, loader.config)

      repos = if repo = options.repo
                [repo]
              else
                loader.repo_names
              end

      case options.mode
      when "status"
        engine.status(repos)
      when "apply"
        engine.apply(repos, dry_run: options.dry_run?)
      else
        STDERR.puts "gitorules: unknown subcommand '#{options.mode}'"
        raise ExitSignal.new(1)
      end

      0
    end
  end
end
