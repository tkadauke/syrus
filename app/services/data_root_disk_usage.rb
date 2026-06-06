require "open3"
require "fileutils"

class DataRootDiskUsage
  CACHE_TTL = 2.minutes
  CACHE_KEY = "data_root_disk_usage/v1/current".freeze
  WARNING_USED_PERCENT = 85
  CRITICAL_USED_PERCENT = 95
  CRITICAL_AVAILABLE_BYTES = 5.gigabytes

  Snapshot = Data.define(
    :path,
    :filesystem,
    :total_bytes,
    :used_bytes,
    :available_bytes,
    :used_percent,
    :mounted_on,
    :observed_at
  ) do
    def level
      return :critical if used_percent >= CRITICAL_USED_PERCENT || available_bytes < CRITICAL_AVAILABLE_BYTES
      return :warning if used_percent >= WARNING_USED_PERCENT

      :ok
    end

    def alert?
      level != :ok
    end

    def as_json(*)
      {
        path: path,
        filesystem: filesystem,
        total_bytes: total_bytes,
        used_bytes: used_bytes,
        available_bytes: available_bytes,
        used_percent: used_percent,
        mounted_on: mounted_on,
        observed_at: observed_at.iso8601,
        level: level.to_s
      }
    end
  end

  class << self
    def current
      Rails.cache.read(CACHE_KEY)
    end

    def refresh!
      snapshot = read(WorkflowWorkspace.data_root.to_s)
      Rails.cache.write(CACHE_KEY, snapshot, expires_in: CACHE_TTL) if snapshot
      snapshot
    end

    def read(path)
      FileUtils.mkdir_p(path)
      output, err, status = Open3.capture3("df", "-Pk", path.to_s)
      raise "df failed: #{err.presence || output}" unless status.success?

      parse_df(output, path: path.to_s)
    rescue => e
      Rails.logger.warn("[DataRootDiskUsage] failed to read disk usage for #{path}: #{e.class}: #{e.message}")
      nil
    end

    def parse_df(output, path:)
      lines = output.lines.map(&:strip).reject(&:empty?)
      row = lines[1]
      raise "unexpected df output" unless row

      fields = row.split(/\s+/, 6)
      raise "unexpected df row: #{row}" unless fields.size == 6

      filesystem, total_kb, used_kb, available_kb, capacity, mounted_on = fields
      Snapshot.new(
        path: path,
        filesystem: filesystem,
        total_bytes: total_kb.to_i.kilobytes,
        used_bytes: used_kb.to_i.kilobytes,
        available_bytes: available_kb.to_i.kilobytes,
        used_percent: capacity.delete("%").to_i,
        mounted_on: mounted_on,
        observed_at: Time.current
      )
    end
  end
end
