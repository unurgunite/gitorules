require "colorize"

module Gitorules
  # Protocol for managed resources.
  #
  # Each resource implements status, diff and apply operations over a
  # list of repositories. Engine delegates to registered resources and
  # keeps CLI output stable.
  abstract class Resource
    # Shows human-readable status for repositories.
    #
    # @param repos [Array(String)] Full repository names
    # @param quiet [Bool] Suppress per-repo lines, print summary only
    # @param io [IO] Output stream
    abstract def status(repos : Array(String), quiet : Bool, io : IO)

    # Shows machine-readable status for repositories.
    #
    # @param repos [Array(String)] Full repository names
    # @param io [IO] Output stream
    abstract def status_json(repos : Array(String), io : IO)

    # Shows human-readable pending changes.
    #
    # @param repos [Array(String)] Full repository names
    # @param quiet [Bool] Suppress per-repo lines, print summary only
    # @param io [IO] Output stream
    abstract def diff(repos : Array(String), quiet : Bool, io : IO)

    # Shows machine-readable pending changes.
    #
    # @param repos [Array(String)] Full repository names
    # @param io [IO] Output stream
    abstract def diff_json(repos : Array(String), io : IO)

    # Applies wanted state to repositories.
    #
    # @param repos [Array(String)] Full repository names
    # @param dry_run [Bool] Preview changes without modifying
    # @param quiet [Bool] Suppress per-repo lines, print summary only
    # @param io [IO] Output stream
    abstract def apply(repos : Array(String), dry_run : Bool, quiet : Bool, io : IO)

    # Applies wanted state, reporting machine-readable results.
    #
    # @param repos [Array(String)] Full repository names
    # @param dry_run [Bool] Preview changes without modifying
    # @param io [IO] Output stream
    abstract def apply_json(repos : Array(String), dry_run : Bool, io : IO)

    protected def pad_to(text : String, width : Int32) : String
      plain = text.gsub(/\e\[[0-9;]*m/, "")
      text + " " * Math.max(0, width - plain.size)
    end

    protected def colorize?(io : IO) : Bool
      io.responds_to?(:tty?) && io.tty?
    end

    protected def green(text : String, io : IO) : String
      colorize?(io) ? text.colorize.green.to_s : text
    end

    protected def red(text : String, io : IO) : String
      colorize?(io) ? text.colorize.red.to_s : text
    end

    protected def yellow(text : String, io : IO) : String
      colorize?(io) ? text.colorize.yellow.to_s : text
    end

    protected def dim(text : String, io : IO) : String
      colorize?(io) ? text.colorize.dim.to_s : text
    end
  end
end
