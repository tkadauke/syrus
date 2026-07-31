class WorkerHostHealthSampler
  CpuSnapshot = Data.define(:idle, :total)

  class << self
    def record!(instance:, observed_at: Time.current, data_root_snapshot: nil)
      return unless instance

      metrics = sample(observed_at: observed_at, data_root_snapshot: data_root_snapshot)
      WorkerHostHealthSample.create!(
        metrics.merge(
          hostname: instance.hostname,
          role: instance.role,
          version: instance.version,
          observed_at: observed_at
        )
      )
    end

    def sample(observed_at: Time.current, data_root_snapshot: nil)
      cpu = cpu_used_percent
      memory = memory_metrics
      data_root = data_root_snapshot || data_root_metrics
      pressure = pressure_metrics

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
        cpu_pressure_some: pressure.dig(:cpu, :some),
        cpu_pressure_full: pressure.dig(:cpu, :full),
        io_pressure_some: pressure.dig(:io, :some),
        io_pressure_full: pressure.dig(:io, :full),
        raw_metrics: raw_metrics(data_root: data_root, observed_at: observed_at)
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

    def pressure_metrics
      {
        cpu: read_pressure("/proc/pressure/cpu"),
        io: read_pressure("/proc/pressure/io")
      }
    end

    def read_pressure(path)
      parse_pressure(File.read(path))
    rescue Errno::ENOENT
      {}
    rescue StandardError => e
      Rails.logger.debug { "[WorkerHostHealthSampler] pressure sample failed: #{path}: #{e.class}: #{e.message}" }
      {}
    end

    def raw_metrics(data_root:, observed_at:)
      raw = { sampler: "worker_host_health_sampler", observed_at: observed_at.iso8601 }
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
