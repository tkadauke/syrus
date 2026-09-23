module Syrus
  # Prefixes a shell command so it competes for disk I/O and CPU scheduling at
  # the lowest priority Linux offers (`ionice -c3`, the "idle" I/O class, plus
  # `nice -n 19`). Used for background filesystem maintenance -- chat
  # workspace pruning/reclaim -- that runs in the same worker process as
  # latency-sensitive foreground work (live chat turns, dependency installs,
  # agent home writes) sharing the same node-local disk. A `du -sk` treewalk
  # or `rm -rf` over a multi-gigabyte checkout can otherwise saturate that
  # disk long enough to stall an unrelated few-KB write elsewhere in the pod.
  #
  # Falls back to the bare command when `ionice`/`nice` aren't on PATH (a
  # minimal container image, macOS dev, or CI) -- correctness never depends on
  # the wrapper actually working, only scheduling priority does.
  module LowPriorityIo
    class << self
      def wrap(command)
        prefix = []
        prefix += [ "ionice", "-c3" ] if binary_available?("ionice")
        prefix += [ "nice", "-n", "19" ] if binary_available?("nice")
        prefix + command
      end

      # Test-only: clears the memoized PATH lookups so specs can simulate a
      # host without ionice/nice.
      def reset_memoization_for_test!
        @availability = nil
      end

      private

      def binary_available?(name)
        availability.fetch(name) do
          availability[name] = path_dirs.any? { |dir| File.executable?(File.join(dir, name)) }
        end
      end

      def availability
        @availability ||= {}
      end

      def path_dirs
        ENV["PATH"].to_s.split(File::PATH_SEPARATOR)
      end
    end
  end
end
