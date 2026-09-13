module Gitorules
  # Bounded fiber pool for per-repo work.
  #
  # Runs per-repo tasks concurrently with a fixed number of worker
  # fibers communicating over Channels. Results are returned in the
  # original input order so human and JSON output stays stable.
  # Memory buffer that reports a fixed tty status.
  #
  # Lets worker fibers format output with the same color decisions
  # as the final IO while still buffering per-repo text for ordered
  # output.
  class TtyMemory < IO::Memory
    def initialize(@force_tty : Bool = false)
      super()
    end

    def tty? : Bool
      @force_tty
    end
  end

  module Concurrent
    # Maximum number of concurrent worker fibers.
    POOL_SIZE = 10

    # Maps items to results using a bounded worker pool.
    #
    # @param items [Array(T)] Input items in desired output order
    # @param pool_size [Int32] Number of worker fibers (default: POOL_SIZE)
    # @return [Array(U)] Results in the same order as *items*
    # @raise [Exception] Reraises the first worker exception, if any
    def self.map_ordered(items : Array(T), pool_size : Int32 = POOL_SIZE, &block : T, Int32 -> U) : Array(U) forall T, U
      n = items.size
      return [] of U if n.zero?

      workers = pool_size.clamp(1, n)
      jobs = Channel({Int32, T} | Nil).new(n + workers)
      results = Channel({Int32, U | Exception}).new(n)
      handler = block

      workers.times do
        spawn do
          loop do
            job = jobs.receive
            break if job.nil?
            idx, item = job
            begin
              results.send({idx, handler.call(item, idx)})
            rescue ex
              results.send({idx, ex})
            end
          end
        end
      end

      items.each_with_index do |item, idx|
        jobs.send({idx, item})
      end
      workers.times { jobs.send(nil) }

      ordered = Array(U | Exception?).new(n, nil)
      n.times do
        idx, value = results.receive
        ordered[idx] = value
      end

      ordered.map do |value|
        raise value if value.is_a?(Exception)
        value.as(U)
      end
    end
  end
end
