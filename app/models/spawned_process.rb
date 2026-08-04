class SpawnedProcess < ApplicationRecord
  include TracksFinishedAt

  # The strict set of process kinds we know how to handle. Adding a
  # new kind means appending it here AND wiring the caller to pass
  # `kind:` to ProcessRunner. We use a CONSTANT instead of an AR enum
  # so the validation error is explicit ("kind 'mcp_sidecar' is not in
  # the strict list") rather than the silent AR coercion enum gives.
  KINDS = %w[ agent grader git prepare chat_prepare ].freeze

  # Terminal outcomes. Surfaced to the admin UI as colored pills.
  OUTCOMES = %w[
    succeeded
    failed
    timed_out
    silent_timed_out
    aliveness_failed
    operator_killed
    stopped
    orphaned
  ].freeze

  STALE_THRESHOLD = 5.minutes

  belongs_to :run, optional: true
  belongs_to :workflow, optional: true
  belongs_to :kill_requested_by_user, class_name: "User", optional: true
  has_many :command_spans, dependent: :nullify

  validates :kind, presence: true, inclusion: { in: KINDS,
            message: ->(_, value) { "#{value[:value].inspect} is not in SpawnedProcess::KINDS — register it explicitly before spawning" } }
  validates :command, :hostname, :started_at, presence: true
  validates :outcome, inclusion: { in: OUTCOMES, allow_nil: true }

  scope :stale, ->(threshold = STALE_THRESHOLD) {
    running.where("(last_chunk_at IS NULL AND started_at < :t) OR last_chunk_at < :t", t: threshold.ago)
  }
  scope :recent_or_active, ->(window = 1.hour) {
    where("finished_at IS NULL OR finished_at >= ?", window.ago)
  }

  def stale?(threshold = STALE_THRESHOLD)
    return false if finished?

    cutoff = threshold.ago
    (last_chunk_at || started_at) < cutoff
  end

  def duration_s
    end_time = finished_at || Time.current
    (end_time - started_at).to_f
  end

  def kill_requested?
    kill_requested_at.present?
  end

  def redacted_command
    CommandRedactor.redact(command)
  end

  # Operator pressed the kill button. The worker pod's ProcessRunner
  # polls this flag once per second; when it flips, the local stream
  # loop terminates the process group. We do NOT send signals from
  # here — the web pod and worker pod can be different hosts, and pid
  # numbers are per-host. The DB flag is the cross-pod signal.
  def request_kill!(user:)
    update!(kill_requested_at: Time.current, kill_requested_by_user: user)
  end

  # Reads /proc/<pid>/status + /proc/<pid>/stat for resident memory
  # and approximate cpu time. Linux-only (worker pods are linux/amd64
  # per CLAUDE.md). Returns nil on Mac dev or if the pid is gone.
  # Computed on demand by the admin UI — not persisted.
  def host_metrics
    return nil unless running? && pid && Etc.uname[:sysname] == "Linux"

    status_path = "/proc/#{pid}/status"
    stat_path = "/proc/#{pid}/stat"
    return nil unless File.exist?(status_path) && File.exist?(stat_path)

    rss_kb = nil
    vsz_kb = nil
    state = nil
    File.foreach(status_path) do |line|
      case line
      when /\AVmRSS:\s+(\d+)/
        rss_kb = Integer(Regexp.last_match(1))
      when /\AVmSize:\s+(\d+)/
        vsz_kb = Integer(Regexp.last_match(1))
      when /\AState:\s+(\S)/
        state = Regexp.last_match(1)
      end
    end

    stat_fields = File.read(stat_path).split(" ")
    utime_jiffies = Integer(stat_fields[13]) rescue nil
    stime_jiffies = Integer(stat_fields[14]) rescue nil
    starttime_jiffies = Integer(stat_fields[21]) rescue nil
    cpu_seconds = ((utime_jiffies.to_i + stime_jiffies.to_i).to_f) / hz

    {
      state: state,
      rss_bytes: rss_kb && (rss_kb * 1024),
      vsz_bytes: vsz_kb && (vsz_kb * 1024),
      cpu_seconds: cpu_seconds,
      cpu_percent: cpu_percent(cpu_seconds, starttime_jiffies)
    }
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end

  private

  def hz
    @hz ||= begin
      out = `getconf CLK_TCK 2>/dev/null`.strip
      Integer(out)
    rescue StandardError
      100
    end
  end

  def cpu_percent(cpu_seconds, starttime_jiffies)
    return nil unless starttime_jiffies

    boot_time = system_boot_time
    return nil unless boot_time

    started_at_unix = boot_time + (starttime_jiffies.to_f / hz)
    elapsed = Time.now.to_f - started_at_unix
    return nil if elapsed <= 0

    ((cpu_seconds / elapsed) * 100).round(1)
  end

  def system_boot_time
    @system_boot_time ||= begin
      uptime_seconds = Float(File.read("/proc/uptime").split(" ").first)
      Time.now.to_f - uptime_seconds
    rescue StandardError
      nil
    end
  end
end
