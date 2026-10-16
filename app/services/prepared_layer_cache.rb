require "fileutils"
require "json"

# Host-level cache of prepared workspace trees, shared by every workflow that
# runs on this worker.
#
# It used to live inside the workflow's own workspace, keyed by workflow id, so
# a tree was downloaded, untarred and then deleted again for every workflow --
# ~1.6 GB per workflow per host, even when the workflow that ran a minute
# earlier had an identical one. Keying by the prepare fingerprint instead makes
# it reusable: the fingerprint already covers the prepare plan *and* the worker
# capability environment (see PreparedWorkspaceArchive.prepare_fingerprint_for),
# so two trees with the same fingerprint are interchangeable on this host.
#
# Because entries now outlive the workflows that produced them, the cache
# bounds itself: least-recently-used entries are evicted once the cache is over
# budget, or once the data root itself is under disk pressure. The budget is an
# instance-wide size with a per-host override, since a 256 GB laptop worker and
# a 1 TB server should not be told the same number.
class PreparedLayerCache
  ROOT_DIRNAME = "prepared-layers".freeze
  METADATA_FILENAME = ".syrus-layer.json".freeze
  BUDGET_ENV_VAR = "SYRUS_PREPARED_LAYER_CACHE_GB".freeze
  DEFAULT_BUDGET_GIGABYTES = 100

  # An entry that a Run is using right now must not be evicted under it, and a
  # lock held for the life of a Run is awkward to reason about across process
  # restarts. Last-use timestamps plus a grace window longer than any grader
  # run gives the same protection without the lifetime problem: a sweep only
  # ever considers entries nothing has touched for hours.
  EVICTION_GRACE = 2.hours

  Entry = Data.define(:path, :fingerprint, :source_sha, :bytes, :last_used_at)

  class << self
    def root
      WorkflowWorkspace.data_root.join(ROOT_DIRNAME)
    end

    # `source_sha` is part of the key while an entry is a full checkout. Once
    # the dependency closure is stored on its own, the fingerprint alone is the
    # key and the source is checked out on top of it.
    def path_for(fingerprint:, source_sha: nil)
      root.join(*[ sanitize(fingerprint), sanitize(source_sha) ].compact)
    end

    # Records that an entry was just materialized or reused. The size is
    # measured once, at materialization, so an eviction sweep can add entries up
    # without walking ~69,000 files per entry to do it.
    def record_use!(path, now: Time.current)
      path = Pathname.new(path)
      return unless path.directory?

      metadata_path = path.join(METADATA_FILENAME)
      bytes = read_metadata(metadata_path)["bytes"] || measure_bytes(path)
      metadata_path.write(JSON.generate("bytes" => bytes, "last_used_at" => now.iso8601))
      bytes
    rescue SystemCallError, JSON::GeneratorError
      nil
    end

    def budget_bytes
      configured = ENV[BUDGET_ENV_VAR]
      return gigabytes_to_bytes(configured.to_f) if configured.present?

      gigabytes_to_bytes(AppSetting.prepared_layer_cache_gb)
    end

    # Evicts least-recently-used entries until the cache fits its budget. Also
    # evicts while the data root is in disk trouble regardless of the budget:
    # a full data root takes the whole worker out of rotation (see
    # RunHostAdmission), which is worse than losing a cached tree.
    def evict_over_budget!(keep: nil, now: Time.current, log: nil)
      budget = budget_bytes
      candidates = entries(now: now)
      total = candidates.sum(&:bytes)
      keep_path = keep && Pathname.new(keep).to_s
      evictable = candidates
        .reject { |entry| entry.path.to_s == keep_path }
        .reject { |entry| entry.last_used_at > now - EVICTION_GRACE }
        .sort_by(&:last_used_at)

      evicted = []
      evictable.each do |entry|
        break unless over_budget?(total: total, budget: budget)

        FileUtils.rm_rf(entry.path.to_s)
        total -= entry.bytes
        evicted << entry
        log&.call("[prepared_layer_cache] evicted #{entry.path.basename} (#{(entry.bytes / 1024.0**3).round(1)} GB, last used #{entry.last_used_at.iso8601})")
      end
      evicted
    end

    def entries(now: Time.current)
      return [] unless root.directory?

      root.children.select(&:directory?).flat_map do |fingerprint_path|
        fingerprint_path.children.select(&:directory?).map do |entry_path|
          metadata = read_metadata(entry_path.join(METADATA_FILENAME))
          Entry.new(
            entry_path,
            fingerprint_path.basename.to_s,
            entry_path.basename.to_s,
            metadata["bytes"] || measure_bytes(entry_path),
            parse_time(metadata["last_used_at"]) || mtime(entry_path) || now
          )
        end
      end
    end

    private

    def over_budget?(total:, budget:)
      return true if disk_pressure?
      return false unless budget.positive?

      total > budget
    end

    def disk_pressure?
      DataRootDiskUsage.current.alert?
    rescue StandardError
      false
    end

    def gigabytes_to_bytes(gigabytes)
      (gigabytes.to_f * 1024**3).to_i
    end

    def read_metadata(path)
      JSON.parse(path.read)
    rescue StandardError
      {}
    end

    def parse_time(value)
      Time.zone.parse(value.to_s)
    rescue StandardError
      nil
    end

    def mtime(path)
      path.mtime
    rescue SystemCallError
      nil
    end

    def measure_bytes(path)
      Dir.glob(path.join("**", "*").to_s, File::FNM_DOTMATCH).sum do |entry|
        stat = File.lstat(entry)
        stat.file? ? stat.size : 0
      rescue SystemCallError
        0
      end
    end

    def sanitize(component)
      component.to_s.gsub(/[^A-Za-z0-9._-]/, "-").presence
    end
  end
end
