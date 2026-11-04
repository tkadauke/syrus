require "objspace"
require "zlib"

module Diagnostics
  # The heap diagnostics, registered with SignalTrigger. Three tiers, cheapest
  # first, because the expensive ones are genuinely risky on a worker that is
  # already near its memory limit.
  #
  #   gc_stat        free        counters only; answers "retained or bloated?"
  #   heap_histogram seconds     per-class counts and sizes; names the classes
  #   heap_dump      expensive   full object graph; reference chains to roots
  #
  # Use gc_stat to decide whether there is a retention problem, heap_histogram
  # to find out what is being retained, and heap_dump only when you need to
  # know what is holding the references.
  module HeapDiagnostics
    DEFAULT_TOP_N = 50
    MAX_TOP_N = 500
    # heap_dump allocates while it writes, and the output is several times the
    # heap it describes. Taking it on a nearly-full pod kills the process
    # holding the evidence, so it is refused above this share of the cgroup
    # limit unless the request forces it.
    DUMP_MEMORY_CEILING = 0.75
    DEFAULT_TRACE_SECONDS = 30
    MAX_TRACE_SECONDS = 300

    class << self
      def register!
        SignalTrigger.register("gc_stat") { |request| gc_stat(request) }
        SignalTrigger.register("heap_histogram") { |request| histogram(request) }
        SignalTrigger.register("heap_dump") { |request| dump(request) }
        SignalTrigger.register("allocation_trace") { |request| allocation_trace(request) }
      end

      # Turns "we are retaining String" into "allocated at app/services/x.rb:42".
      # Tracing records a source location on every object allocated while it is
      # on, so this only sees allocations made during the window -- which is
      # the point: objects that survive the window are the ones leaking.
      #
      # Roughly doubles memory while active, so it carries the same headroom
      # guard as heap_dump and always stops, including on error.
      def allocation_trace(request)
        unless request.options["force"] || headroom?
          raise "refusing allocation_trace: cgroup memory is above #{(DUMP_MEMORY_CEILING * 100).round}% of the limit. " \
                'Tracing roughly doubles memory. Restart the worker for room, or set {"force": true}.'
        end

        seconds = request.fetch_integer(:seconds, default: DEFAULT_TRACE_SECONDS, max: MAX_TRACE_SECONDS)
        top_n = request.fetch_integer(:top_n, default: DEFAULT_TOP_N, max: MAX_TOP_N)
        before = GC.stat(:total_allocated_objects)

        ObjectSpace.trace_object_allocations_start
        begin
          sleep(seconds)
          # Collect while tracing is still on: allocation metadata is dropped
          # by trace_object_allocations_clear, and stopping then clearing is
          # what releases the overhead.
          sites = collect_allocation_sites
        ensure
          ObjectSpace.trace_object_allocations_stop
          ObjectSpace.trace_object_allocations_clear
        end

        gc_stat(request).merge(
          "traced_seconds" => seconds,
          "allocated_during_window" => GC.stat(:total_allocated_objects) - before,
          "top_n" => top_n,
          "sites_seen" => sites.size,
          "top_allocation_sites" => allocation_rows(sites, top_n)
        )
      end

      # Counters only -- no heap walk, no measurable pause. heap_live_slots
      # rising across captures while RSS also rises means objects are still
      # reachable (a leak). RSS high with live slots flat means the heap is
      # simply not being returned to the OS (bloat), which is a different fix.
      def gc_stat(request)
        base(request).merge(
          "gc_stat" => GC.stat.transform_keys(&:to_s),
          "count_objects" => ObjectSpace.count_objects.transform_keys(&:to_s)
        )
      end

      # Walks every live object once, attributing count and retained size per
      # class. This is the one that names the culprit.
      def histogram(request)
        top_n = request.fetch_integer(:top_n, default: DEFAULT_TOP_N, max: MAX_TOP_N)
        counts = Hash.new(0)
        sizes = Hash.new(0)

        ObjectSpace.each_object do |object|
          name = class_name_of(object)
          counts[name] += 1
          sizes[name] += memsize_of(object)
        end

        gc_stat(request).merge(
          "top_n" => top_n,
          "classes_seen" => counts.size,
          "top_by_count" => rows(counts, sizes, counts.keys, top_n) { |name| -counts[name] },
          "top_by_memsize" => rows(counts, sizes, sizes.keys, top_n) { |name| -sizes[name] }
        )
      end

      # Returns the path it wrote rather than a Hash: the dump is far too large
      # to build in memory, which is the whole reason it streams.
      def dump(request)
        unless request.options["force"] || headroom?
          raise "refusing heap_dump: cgroup memory is above #{(DUMP_MEMORY_CEILING * 100).round}% of the limit. " \
                'Restart the worker to make room, or set {"force": true} in the request file.'
        end

        # dump_all only accepts a real IO, not a GzipWriter, so this writes raw
        # and compresses in a second streaming pass rather than building the
        # dump in memory -- which is the thing the whole tier exists to avoid.
        # Peak disk is therefore the raw dump plus its compressed copy; the
        # dump is several times the size of the heap, so check the volume has
        # room before reaching for this tier.
        raw = request.path_for("json")
        compressed = "#{raw}.gz"
        File.open(raw, "w") { |file| ObjectSpace.dump_all(output: file) }
        Zlib::GzipWriter.open(compressed) do |gz|
          File.open(raw, "rb") { |file| IO.copy_stream(file, gz) }
        end
        compressed
      ensure
        File.unlink(raw) if raw && File.exist?(raw)
      end

      private

      # Objects still live at the end of the window, grouped by where they were
      # allocated. Survivors are what matter: anything allocated and collected
      # inside the window never shows up here.
      def collect_allocation_sites
        sites = Hash.new { |hash, key| hash[key] = { "count" => 0, "memsize" => 0, "classes" => Hash.new(0) } }
        ObjectSpace.each_object do |object|
          file = ObjectSpace.allocation_sourcefile(object)
          next unless file

          key = "#{file}:#{ObjectSpace.allocation_sourceline(object)}"
          entry = sites[key]
          entry["count"] += 1
          entry["memsize"] += memsize_of(object)
          entry["classes"][class_name_of(object)] += 1
        end
        sites
      rescue StandardError
        {}
      end

      def allocation_rows(sites, limit)
        sites.sort_by { |_site, entry| -entry["count"] }.first(limit).map do |site, entry|
          {
            "site" => site,
            "count" => entry["count"],
            "memsize" => entry["memsize"],
            "classes" => entry["classes"].sort_by { |_name, count| -count }.first(5).to_h
          }
        end
      end

      def base(request)
        {
          "kind" => request.kind,
          "captured_at" => request.started_at.utc.iso8601,
          "pid" => request.pid,
          "process_title" => $0,
          "memory" => memory_snapshot
        }
      end

      def rows(counts, sizes, keys, limit)
        keys.sort_by { |name| yield(name) }.first(limit).map do |name|
          { "class" => name, "count" => counts[name], "memsize" => sizes[name] }
        end
      end

      # BasicObject has no #class, and memsize_of raises on a few internal
      # types. Neither should abort a whole-heap walk that is already underway.
      def class_name_of(object)
        klass = Object.instance_method(:class).bind_call(object)
        klass.name || klass.to_s
      rescue StandardError
        "(unknown)"
      end

      def memsize_of(object)
        ObjectSpace.memsize_of(object)
      rescue StandardError
        0
      end

      def memory_snapshot
        {
          "cgroup_current_bytes" => RunProcessParallelism.cgroup_memory_current_bytes,
          "cgroup_limit_bytes" => RunProcessParallelism.effective_memory_limit_bytes
        }.compact
      end

      def headroom?
        current = RunProcessParallelism.cgroup_memory_current_bytes
        limit = RunProcessParallelism.effective_memory_limit_bytes
        return true unless current && limit&.positive?

        current < limit * DUMP_MEMORY_CEILING
      end
    end
  end
end
