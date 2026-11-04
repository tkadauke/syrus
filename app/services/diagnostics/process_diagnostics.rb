require "etc"

module Diagnostics
  # Process-level diagnostics: what this process is doing, what it is waiting
  # on, and what it has open. All of these are cheap enough to run on a loaded
  # worker without a headroom guard -- none walks the heap or allocates
  # meaningfully.
  module ProcessDiagnostics
    DEFAULT_BACKTRACE_DEPTH = 40
    MAX_BACKTRACE_DEPTH = 200
    OVERVIEW_BACKTRACE_DEPTH = 8
    MAX_FD_TARGETS = 40

    class << self
      def register!
        SignalTrigger.register("thread_backtraces") { |request| thread_backtraces(request) }
        SignalTrigger.register("db_pool") { |request| db_pool(request) }
        SignalTrigger.register("fd_table") { |request| fd_table(request) }
        SignalTrigger.register("process_overview") { |request| process_overview(request) }
      end

      # "What is this process actually doing right now?" -- the question behind
      # every wedged worker and stalled Run. Capturing a backtrace per thread
      # costs microseconds and pauses nothing, so this is the first thing to
      # reach for and safe to take repeatedly: two captures a few seconds apart
      # distinguish a thread that is stuck from one that is merely busy.
      def thread_backtraces(request)
        depth = request.fetch_integer(:depth, default: DEFAULT_BACKTRACE_DEPTH, max: MAX_BACKTRACE_DEPTH)

        base(request).merge(
          "thread_count" => Thread.list.size,
          "threads" => Thread.list.map { |thread| thread_json(thread, depth) }
        )
      end

      # Connection starvation looks exactly like slow queries from the outside:
      # requests take seconds, the database is idle. The difference is `waiting`
      # -- if threads are queued for a connection, no query optimisation helps
      # and the pool or the thread count is the thing to change.
      def db_pool(request)
        base(request).merge("pools" => pools_json)
      end

      # Descriptor leaks surface as mysterious intermittent failures well
      # before the limit is reached, and nothing else reports them.
      def fd_table(request)
        base(request).merge("file_descriptors" => fd_summary)
      end

      # The "something is wrong and I do not know what yet" entry point, so
      # triage does not need three signals. Backtraces are shallow here on
      # purpose; take thread_backtraces for the full depth once this points
      # somewhere.
      def process_overview(request)
        base(request).merge(
          "gc_stat" => GC.stat.transform_keys(&:to_s),
          "thread_count" => Thread.list.size,
          "threads" => Thread.list.map { |thread| thread_json(thread, OVERVIEW_BACKTRACE_DEPTH) },
          "pools" => pools_json,
          # Keeps "available" so the composite still reports something on a
          # platform without /proc rather than an empty object.
          "file_descriptors" => fd_summary.slice("total", "by_kind", "available")
        )
      end

      private

      def base(request)
        {
          "kind" => request.kind,
          "captured_at" => request.started_at.utc.iso8601,
          "pid" => request.pid,
          "process_title" => $0,
          "uptime_seconds" => uptime_seconds,
          "memory" => {
            "cgroup_current_bytes" => RunProcessParallelism.cgroup_memory_current_bytes,
            "cgroup_limit_bytes" => RunProcessParallelism.effective_memory_limit_bytes
          }.compact
        }
      end

      # `status` is the useful field and its encoding is easy to misread:
      # "run"/"sleep" are alive, false means finished normally, nil means the
      # thread died on an exception. Reported verbatim rather than normalised
      # so a dead-on-exception thread stays distinguishable.
      def thread_json(thread, depth)
        {
          "name" => thread.name,
          "main" => thread == Thread.main,
          "status" => thread.status.inspect,
          "alive" => thread.alive?,
          "backtrace" => Array(thread.backtrace).first(depth)
        }
      rescue StandardError => e
        { "name" => (thread.name rescue nil), "error" => "#{e.class}: #{e.message}" }
      end

      # connection_pool_list(:all) is the Rails 8 API. An earlier version of
      # this used all_connection_pools, which does not exist here, and a
      # blanket rescue turned that into a silent empty list -- so the failure
      # is surfaced in the payload rather than swallowed.
      def connection_pools
        handler = ActiveRecord::Base.connection_handler
        return handler.connection_pool_list(:all) if handler.respond_to?(:connection_pool_list)

        handler.all_connection_pools
      end

      def pools_json
        connection_pools.map { |pool| pool_json(pool) }
      rescue StandardError => e
        [ { "error" => "#{e.class}: #{e.message}" } ]
      end

      def pool_json(pool)
        stat = pool.stat
        {
          "name" => (pool.db_config.name rescue nil),
          "size" => stat[:size],
          "connections" => stat[:connections],
          "busy" => stat[:busy],
          "idle" => stat[:idle],
          "dead" => stat[:dead],
          # Non-zero means threads are blocked waiting for a connection. That
          # is the signal this diagnostic exists for.
          "waiting" => stat[:waiting],
          "checkout_timeout" => stat[:checkout_timeout]
        }.compact
      rescue StandardError => e
        { "error" => "#{e.class}: #{e.message}" }
      end

      # Linux only -- /proc/self/fd does not exist on macOS, where this reports
      # unavailable rather than guessing.
      def fd_summary
        entries = Dir.children("/proc/self/fd")
        targets = entries.filter_map { |fd| fd_target(fd) }
        by_kind = targets.group_by { |target| fd_kind(target) }.transform_values(&:size)
        repeated = targets.tally.select { |_target, count| count > 1 }
          .sort_by { |_target, count| -count }.first(MAX_FD_TARGETS).to_h

        { "total" => entries.size, "by_kind" => by_kind, "most_repeated_targets" => repeated }
      rescue SystemCallError, Errno::ENOENT
        { "available" => false, "reason" => "/proc/self/fd is not readable on this platform" }
      end

      def fd_target(fd)
        File.readlink(File.join("/proc/self/fd", fd))
      rescue SystemCallError
        nil
      end

      def fd_kind(target)
        case target
        when /\Asocket:/ then "socket"
        when /\Apipe:/ then "pipe"
        when /\Aanon_inode:/ then "anon_inode"
        when %r{\A/dev/} then "device"
        else "file"
        end
      end

      # /proc/self/stat field 22 is starttime measured in clock ticks since
      # *boot*, not elapsed time, so it has to be subtracted from the system
      # uptime. Reading it as elapsed directly reports the age of the machine.
      # The comm field can contain spaces and parentheses, hence parsing after
      # the last ")" rather than splitting the whole line.
      def uptime_seconds
        stat = File.read("/proc/self/stat")
        fields = stat[(stat.rindex(")") + 2)..].split
        started_ticks = Integer(fields[19])
        boot_seconds = Float(File.read("/proc/uptime").split.first)
        (boot_seconds - started_ticks / clock_ticks.to_f).round(1)
      rescue StandardError
        nil
      end

      # Etc.sysconf rather than shelling out to getconf: a diagnostic has no
      # business spawning a process (the ProcessRunner boundary forbids it),
      # and this is the same value without the fork.
      def clock_ticks
        @clock_ticks ||= begin
          value = Etc.sysconf(Etc::SC_CLK_TCK)
          value.to_i.positive? ? value.to_i : 100
        rescue StandardError, NameError
          100
        end
      end
    end
  end
end
