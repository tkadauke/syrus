class ProcessResourceSampler
  VERSION = 1
  METHOD = "linux_proc_process_group".freeze

  def initialize(pid:, pgid: nil)
    @pid = pid
    @pgid = pgid
    @first = nil
    @last = nil
    @sample_count = 0
    @max_rss_bytes = nil
    @max_descendant_process_count = 0
  end

  def sample!
    return unless linux?
    return if pid.blank?

    metrics = process_ids.filter_map { |process_id| process_metrics(process_id) }
    return if metrics.empty?

    total = {
      cpu_time_seconds: metrics.sum { |metric| metric.fetch(:cpu_time_seconds) },
      rss_bytes: metrics.sum { |metric| metric.fetch(:rss_bytes) },
      read_io_bytes: metrics.sum { |metric| metric.fetch(:read_io_bytes) },
      write_io_bytes: metrics.sum { |metric| metric.fetch(:write_io_bytes) },
      descendant_process_count: [ metrics.size - 1, 0 ].max
    }

    @first ||= total
    @last = total
    @sample_count += 1
    @max_rss_bytes = [ @max_rss_bytes, total.fetch(:rss_bytes) ].compact.max
    @max_descendant_process_count = [ @max_descendant_process_count, total.fetch(:descendant_process_count) ].max
  rescue StandardError => e
    Rails.logger.debug("[ProcessResourceSampler] sample failed for pid #{pid}: #{e.class}: #{e.message}")
  end

  def payload
    return unavailable_payload unless linux?

    {
      "method" => METHOD,
      "version" => VERSION,
      "confidence" => confidence,
      "sample_count" => sample_count,
      "cpu_time_seconds" => delta(:cpu_time_seconds),
      "max_rss_bytes" => max_rss_bytes,
      "read_io_bytes" => delta(:read_io_bytes),
      "write_io_bytes" => delta(:write_io_bytes),
      "descendant_process_count" => max_descendant_process_count,
      "observed_at" => Time.current.iso8601
    }.compact
  end

  private

  attr_reader :pid, :pgid, :first, :last, :sample_count, :max_rss_bytes, :max_descendant_process_count

  def unavailable_payload
    {
      "method" => METHOD,
      "version" => VERSION,
      "confidence" => "unknown",
      "sample_count" => 0,
      "unavailable_reason" => "process resource accounting requires Linux /proc"
    }
  end

  def confidence
    return "unknown" if sample_count.zero?
    return "low" if sample_count == 1

    "medium"
  end

  def delta(key)
    return nil unless first && last

    (last.fetch(key) - first.fetch(key)).round(3)
  end

  def process_ids
    return [ pid ] if pgid.blank?

    Dir.glob("/proc/[0-9]*").filter_map do |path|
      process_id = Integer(File.basename(path))
      process_pgid(process_id) == pgid ? process_id : nil
    rescue ArgumentError
      nil
    end.presence || [ pid ]
  end

  def process_pgid(process_id)
    stat = read_stat(process_id)
    stat && stat.fetch(:pgid)
  end

  def process_metrics(process_id)
    stat = read_stat(process_id)
    return unless stat

    io = read_io(process_id)
    {
      cpu_time_seconds: stat.fetch(:cpu_time_seconds),
      rss_bytes: stat.fetch(:rss_bytes),
      read_io_bytes: io.fetch(:read_io_bytes),
      write_io_bytes: io.fetch(:write_io_bytes)
    }
  end

  def read_stat(process_id)
    raw = File.read("/proc/#{process_id}/stat")
    after_name = raw[(raw.rindex(")") + 2)..]
    fields = after_name.split
    {
      pgid: Integer(fields[2]),
      cpu_time_seconds: (Integer(fields[11]) + Integer(fields[12])).to_f / clock_ticks,
      rss_bytes: Integer(fields[21]) * page_size
    }
  rescue Errno::ENOENT, Errno::EACCES, ArgumentError, TypeError
    nil
  end

  def read_io(process_id)
    values = { read_io_bytes: 0, write_io_bytes: 0 }
    File.foreach("/proc/#{process_id}/io") do |line|
      case line
      when /\Aread_bytes:\s+(\d+)/
        values[:read_io_bytes] = Integer(Regexp.last_match(1))
      when /\Awrite_bytes:\s+(\d+)/
        values[:write_io_bytes] = Integer(Regexp.last_match(1))
      end
    end
    values
  rescue Errno::ENOENT, Errno::EACCES
    values
  end

  def clock_ticks
    @clock_ticks ||= begin
      Integer(`getconf CLK_TCK 2>/dev/null`.strip)
    rescue StandardError
      100
    end
  end

  def page_size
    @page_size ||= begin
      Integer(`getconf PAGESIZE 2>/dev/null`.strip)
    rescue StandardError
      4096
    end
  end

  def linux?
    RUBY_PLATFORM.include?("linux")
  end
end
