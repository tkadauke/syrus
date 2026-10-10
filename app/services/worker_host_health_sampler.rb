class WorkerHostHealthSampler
  CpuSnapshot = Data.define(:idle, :total)
  PressureReading = Data.define(:values, :source, :path)

  class << self
    def record!(instance:, observed_at: Time.current, data_root_snapshot: nil, capability_snapshot: nil)
      return unless instance

      metrics = sample(observed_at: observed_at, data_root_snapshot: data_root_snapshot)
      capability_snapshot ||= WorkerCapabilities.current
      WorkerHostHealthSample.create!(
        metrics.merge(
          hostname: instance.hostname,
          worker_storage_key: WorkerStorageIdentity.queue_key,
          role: instance.role,
          version: instance.version,
          observed_at: observed_at,
          desired_version: instance.desired_version || {},
          macos_updater_status: instance.macos_updater_status || {},
          capabilities: capability_snapshot.fetch(:capabilities),
          capability_diagnostics: capability_snapshot.fetch(:diagnostics)
        )
      )
    end

    def sample(observed_at: Time.current, data_root_snapshot: nil)
      cpu = cpu_used_percent
      memory = memory_metrics
      data_root = data_root_snapshot || data_root_metrics
      pressure = pressure_metrics
      raw_metrics = raw_metrics(data_root: data_root, observed_at: observed_at)
      pressure.each do |kind, reading|
        raw_metrics[:"#{kind}_pressure_source"] = reading.source if reading.source
        raw_metrics[:"#{kind}_pressure_path"] = reading.path if reading.path
      end

      {
        cpu_used_percent: cpu,
        load_1m: load_average[0],
        load_5m: load_average[1],
        load_15m: load_average[2],
        memory_used_percent: memory[:used_percent],
        memory_available_bytes: memory[:available_bytes],
        memory_total_bytes: memory[:total_bytes],
        data_root_used_percent: data_root&.used_percent,
        data_root_available_bytes: data_root&.available_bytes,
        data_root_total_bytes: data_root&.total_bytes,
        cpu_pressure_some: pressure.fetch(:cpu).values[:some],
        cpu_pressure_full: pressure.fetch(:cpu).values[:full],
        io_pressure_some: pressure.fetch(:io).values[:some],
        io_pressure_full: pressure.fetch(:io).values[:full],
        raw_metrics: raw_metrics
      }
    end

    def parse_meminfo(contents)
      fields = contents.lines.each_with_object({}) do |line, memo|
        key, value = line.split(":", 2)
        next unless key && value

        memo[key] = value.to_s.scan(/\d+/).first.to_i.kilobytes
      end
      total = fields["MemTotal"]
      available = fields["MemAvailable"] || fields["MemFree"]
      used_percent = percent(total - available, total) if total && total.positive? && available

      { total_bytes: total, available_bytes: available, used_percent: used_percent }
    end

    def parse_pressure(contents)
      lines = contents.lines.each_with_object({}) do |line, memo|
        parts = line.split
        label = parts.shift
        next unless %w[some full].include?(label)

        avg10 = parts.find { |part| part.start_with?("avg10=") }&.split("=", 2)&.last
        memo[label.to_sym] = avg10.to_f if avg10
      end

      { some: lines[:some], full: lines[:full] }
    end

    def parse_cpu_stat(contents)
      row = contents.lines.find { |line| line.start_with?("cpu ") }
      return nil unless row

      values = row.split.drop(1).map(&:to_i)
      idle = values.fetch(3, 0) + values.fetch(4, 0)
      CpuSnapshot.new(idle: idle, total: values.sum)
    end

    # Lightweight, on-demand IO-pressure + filesystem context snapshot for
    # correlating a single slow operation (see PerformanceLogging's
    # `capture_host_pressure:`) with local storage stalls. Unlike `sample`,
    # this skips the blocking 50ms CPU-delta read and doesn't persist a
    # WorkerHostHealthSample row -- callers just want a few bucketed fields
    # to attach to an already-emitted slow-phase event.
    def io_pressure_snapshot
      pressure = read_pressure_with_source("io")
      data_root = data_root_metrics
      {
        io_pressure_some: pressure.values[:some],
        io_pressure_full: pressure.values[:full],
        io_pressure_source: pressure.source,
        data_root_used_percent: data_root&.used_percent,
        data_root_filesystem: data_root&.filesystem,
        data_root_mounted_on: data_root&.mounted_on
      }.compact
    rescue StandardError => e
      Rails.logger.debug { "[WorkerHostHealthSampler] io pressure snapshot failed: #{e.class}: #{e.message}" }
      {}
    end

    private

    def cpu_used_percent
      first = read_cpu_snapshot
      return nil unless first

      sleep 0.05
      second = read_cpu_snapshot
      return nil unless second

      total_delta = second.total - first.total
      idle_delta = second.idle - first.idle
      return nil unless total_delta.positive?

      percent(total_delta - idle_delta, total_delta)
    rescue StandardError => e
      Rails.logger.debug { "[WorkerHostHealthSampler] cpu sample failed: #{e.class}: #{e.message}" }
      nil
    end

    def read_cpu_snapshot
      parse_cpu_stat(File.read("/proc/stat"))
    rescue Errno::ENOENT
      nil
    end

    def load_average
      File.read("/proc/loadavg").split.first(3).map(&:to_f)
    rescue StandardError => e
      Rails.logger.debug { "[WorkerHostHealthSampler] load sample failed: #{e.class}: #{e.message}" }
      [ nil, nil, nil ]
    end

    def memory_metrics
      parse_meminfo(File.read("/proc/meminfo"))
    rescue StandardError => e
      Rails.logger.debug { "[WorkerHostHealthSampler] memory sample failed: #{e.class}: #{e.message}" }
      {}
    end

    def data_root_metrics
      DataRootDiskUsage.read(WorkflowWorkspace.data_root.to_s)
    rescue StandardError => e
      Rails.logger.debug { "[WorkerHostHealthSampler] data-root sample failed: #{e.class}: #{e.message}" }
      nil
    end

    # cgroup v2 exposes PSI for this container's own cgroup; /proc/pressure
    # is namespace-blind and reports the whole node. A worker therefore
    # inherited pressure generated by unrelated tenants: one production node
    # read `cpu some=66%` from /proc while its own cgroup read 0.00% and the
    # host sat at 5% utilisation, because a co-tenant on that node was being
    # throttled by a CPU quota. Admission believed the node figure and
    # starved runs on an idle worker for hours.
    #
    # Prefer the cgroup, fall back to /proc where cgroup v2 PSI is absent
    # (cgroup v1, PSI disabled, a non-containerised macOS worker), and record
    # which source answered so a future bogus reading is attributable rather
    # than mysterious.
    def pressure_metrics
      readings = {
        cpu: read_pressure_with_source("cpu"),
        io: read_pressure_with_source("io")
      }
      @pressure_sources = readings.each_with_object({}) do |(resource, reading), memo|
        memo[resource] = reading.source if reading.source
      end
      readings
    end

    def pressure_sources
      @pressure_sources || {}
    end

    def read_pressure_with_source(kind)
      pressure_paths(kind).each do |source, path|
        return PressureReading.new(values: parse_pressure(File.read(path)), source: source, path: path)
      rescue Errno::ENOENT
        next
      rescue StandardError => e
        Rails.logger.debug { "[WorkerHostHealthSampler] pressure sample failed: #{path}: #{e.class}: #{e.message}" }
        next
      end

      PressureReading.new(values: {}, source: nil, path: nil)
    end

    def pressure_paths(kind)
      paths = []
      cgroup_path = cgroup_v2_pressure_path("#{kind}.pressure") || "/sys/fs/cgroup/#{kind}.pressure"
      paths << [ "cgroup", cgroup_path ]
      paths << [ "proc", "/proc/pressure/#{kind}" ]
      paths
    end

    def cgroup_v2_pressure_path(filename)
      relative_path = cgroup_v2_relative_path
      return unless relative_path

      File.join("/sys/fs/cgroup", relative_path.delete_prefix("/"), filename)
    end

    def cgroup_v2_relative_path
      File.read("/proc/self/cgroup").each_line do |line|
        hierarchy, controllers, path = line.chomp.split(":", 3)
        return path if hierarchy == "0" && controllers == "" && path.present?
      end
      nil
    rescue Errno::ENOENT
      nil
    rescue StandardError => e
      Rails.logger.debug { "[WorkerHostHealthSampler] cgroup path sample failed: #{e.class}: #{e.message}" }
      nil
    end

    def raw_metrics(data_root:, observed_at:)
      raw = { sampler: "worker_host_health_sampler", observed_at: observed_at.iso8601 }
      raw[:pressure_sources] = pressure_sources if pressure_sources.present?
      raw[:data_root_path] = data_root.path if data_root&.path
      raw[:data_root_filesystem] = data_root.filesystem if data_root&.filesystem
      raw[:data_root_mounted_on] = data_root.mounted_on if data_root&.mounted_on
      raw
    end

    def percent(used, total)
      ((used.to_f / total) * 100).round(2)
    end
  end
end
