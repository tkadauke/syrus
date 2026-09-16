require "open3"

# Hourly job that builds the size/space data the retention admin page
# displays. Reads RetentionPolicyRegistry (never a hand-listed table set, so
# a plugin-contributed retention policy is covered automatically) and caches
# one snapshot per entry plus one shared available-space snapshot, mirroring
# DataRootDiskUsage's cached-snapshot/TTL pattern. The admin page reads these
# caches; it must never compute size estimates synchronously on page load.
class RetentionSizeSnapshotJob < ApplicationJob
  queue_as :cleanup

  CACHE_KEY_PREFIX = "retention_size_snapshot/v1"
  AVAILABLE_SPACE_CACHE_KEY = "#{CACHE_KEY_PREFIX}/available_space".freeze
  CACHE_TTL = 2.hours

  TableSnapshot = Data.define(
    :key,
    :table_name,
    :row_count_estimate,
    :byte_size_estimate,
    :retention_value,
    :retention_unit,
    :bytes_per_unit_estimate,
    :estimated_max_byte_size,
    :computed_at
  ) do
    def as_json(*)
      {
        key: key.to_s,
        table_name: table_name,
        row_count_estimate: row_count_estimate,
        byte_size_estimate: byte_size_estimate,
        retention_value: retention_value,
        retention_unit: retention_unit.to_s,
        bytes_per_unit_estimate: bytes_per_unit_estimate,
        estimated_max_byte_size: estimated_max_byte_size,
        computed_at: computed_at.iso8601
      }
    end
  end

  AvailableSpace = Data.define(:available_bytes, :source, :computed_at) do
    def as_json(*)
      {
        available_bytes: available_bytes,
        source: source.to_s,
        computed_at: computed_at.iso8601
      }
    end
  end

  class << self
    def table_snapshot(key)
      Rails.cache.read(table_cache_key(key))
    end

    def available_space
      Rails.cache.read(AVAILABLE_SPACE_CACHE_KEY)
    end

    def table_cache_key(key)
      "#{CACHE_KEY_PREFIX}/table/#{key}"
    end
  end

  def perform
    RetentionPolicyRegistry.definitions.each do |definition|
      snapshot = build_table_snapshot(definition)
      Rails.cache.write(self.class.table_cache_key(definition.key), snapshot, expires_in: CACHE_TTL)
    end

    Rails.cache.write(AVAILABLE_SPACE_CACHE_KEY, build_available_space_snapshot, expires_in: CACHE_TTL)
  end

  private

  def build_table_snapshot(definition)
    estimate = TableSizeEstimator.estimate(definition.table_name)
    retention_value = AppSetting.current.public_send(definition.setting_key).to_i
    bytes_per_unit, estimated_max = project_max_byte_size(estimate.byte_size_estimate, retention_value)

    TableSnapshot.new(
      key: definition.key,
      table_name: definition.table_name,
      row_count_estimate: estimate.row_count_estimate,
      byte_size_estimate: estimate.byte_size_estimate,
      retention_value: retention_value,
      retention_unit: definition.unit,
      bytes_per_unit_estimate: bytes_per_unit,
      estimated_max_byte_size: estimated_max,
      computed_at: Time.current
    )
  end

  # Infinite retention (0) has no ceiling to project, so it's exposed as
  # unbounded/null rather than a number. An empty table can't yield a
  # meaningful per-unit rate either -- both are the divide-by-zero guard.
  def project_max_byte_size(byte_size, retention_value)
    return [ nil, nil ] if retention_value.zero? || byte_size.to_i.zero?

    bytes_per_unit = byte_size.to_f / retention_value
    estimated_max = (bytes_per_unit * retention_value).round

    [ bytes_per_unit, estimated_max ]
  end

  def build_available_space_snapshot(now: Time.current)
    override_bytes = AppSetting.retention_available_space_override_bytes
    return AvailableSpace.new(available_bytes: override_bytes, source: :manual, computed_at: now) if override_bytes

    measured_bytes = measure_available_space
    if measured_bytes
      AvailableSpace.new(available_bytes: measured_bytes, source: :measured, computed_at: now)
    else
      AvailableSpace.new(available_bytes: nil, source: :unknown, computed_at: now)
    end
  end

  def measure_available_space
    if ENV["SYRUS_SQLITE"].present?
      DataRootDiskUsage.refresh!&.available_bytes
    elsif mysql?
      measure_mysql_datadir_available_bytes
    end
  end

  def mysql?
    ActiveRecord::Base.connection.adapter_name.downcase.include?("mysql")
  end

  # Managed/remote MySQL (the common production case) exposes no locally
  # readable datadir path, so this returns nil rather than erroring; the
  # admin page then falls back to the manual override or reports "unknown".
  def measure_mysql_datadir_available_bytes
    datadir = ActiveRecord::Base.connection.select_value("SELECT @@datadir")
    return nil if datadir.blank? || !File.directory?(datadir)

    output, _err, status = Open3.capture3("df", "-Pk", datadir)
    return nil unless status.success?

    DataRootDiskUsage.parse_df(output, path: datadir).available_bytes
  rescue StandardError => e
    Rails.logger.warn("[RetentionSizeSnapshotJob] failed to measure MySQL datadir space: #{e.class}: #{e.message}")
    nil
  end
end
