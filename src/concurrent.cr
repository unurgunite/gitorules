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
      jobs = Channel({Int32, T}?).new(n + workers)
      results = Channel({Int32, U | Exception}).new(n)

      spawn_workers(workers, jobs, results, &block)
      items.each_with_index { |item, idx| jobs.send({idx, item}) }
      workers.times { jobs.send(nil) }
      gather(results, n)
    end

    # Starts *workers* fibers draining *jobs* into *results*.
    private def self.spawn_workers(workers : Int32, jobs : Channel({Int32, T}?), results : Channel({Int32, U | Exception}), &block : T, Int32 -> U) : Nil forall T, U
      workers.times do
        spawn do
          while job = jobs.receive
            idx, item = job
            begin
              results.send({idx, block.call(item, idx)})
            rescue ex
              results.send({idx, ex})
            end
          end
        end
      end
    end

    # Collects *n* results in input order, reraising the first exception.
    private def self.gather(results : Channel({Int32, U | Exception}), n : Int32) : Array(U) forall U
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
