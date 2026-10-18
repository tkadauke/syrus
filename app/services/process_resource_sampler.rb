class ProcessResourceSampler
  VERSION = 2
  METHOD = "linux_proc_process_group".freeze

  def initialize(pid:, pgid: nil, proc_root: "/proc")
    @pid = pid
    @pgid = pgid
    @proc_root = proc_root
    @first = nil
    @last = nil
    @process_high_water_marks = {}
    @observed_process_ids = Set.new
    @vanished_process_ids = Set.new
    @processes_vanished = false
    @sample_count = 0
    @max_rss_bytes = nil
    @max_descendant_process_count = 0
  end

  def sample!
    return unless linux?
    return if pid.blank?

    metrics_by_process = process_ids.to_h do |process_id|
      [ process_id, process_metrics(process_id) ]
    end.compact
    metrics = metrics_by_process.values
    current_process_ids = metrics_by_process.keys.to_set
    newly_vanished_process_ids = observed_process_ids - current_process_ids
    @processes_vanished ||= newly_vanished_process_ids.any?
    vanished_process_ids.merge(newly_vanished_process_ids)
    return if metrics.empty?

    @observed_process_ids.merge(current_process_ids)
    metrics_by_process.each do |process_id, metric|
      process_high_water_marks[process_id] = cumulative_metric_keys.to_h do |key|
        [ key, [ process_high_water_marks.dig(process_id, key), metric.fetch(key) ].compact.max ]
      end
    end

    total = {
      cpu_time_seconds: cumulative_cpu_time_seconds,
      rss_bytes: metrics.sum { |metric| metric.fetch(:rss_bytes) },
      read_io_bytes: cumulative_total(:read_io_bytes),
      write_io_bytes: cumulative_total(:write_io_bytes),
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

  attr_reader :pid, :pgid, :proc_root, :first, :last, :sample_count, :max_rss_bytes,
    :max_descendant_process_count, :process_high_water_marks, :observed_process_ids
  attr_reader :vanished_process_ids

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
    return "low" if @processes_vanished

    "medium"
  end

  def delta(key)
    return nil unless first && last

    [ last.fetch(key) - first.fetch(key), 0 ].max.round(3)
  end

  def cumulative_metric_keys
    %i[self_cpu_time_seconds children_cpu_time_seconds read_io_bytes write_io_bytes]
  end

  def cumulative_total(key)
    process_high_water_marks.values.sum { |metrics| metrics.fetch(key) }
  end

  def cumulative_cpu_time_seconds
    directly_observed = cumulative_total(:self_cpu_time_seconds)
    waited_children = cumulative_total(:children_cpu_time_seconds)
    transferred_observed = vanished_process_ids.sum do |process_id|
      process_high_water_marks.dig(process_id, :self_cpu_time_seconds).to_f
    end

    directly_observed + [ waited_children - transferred_observed, 0 ].max
  end

  def process_ids
    return [ pid ] if pgid.blank?

    Dir.glob(File.join(proc_root, "[0-9]*")).filter_map do |path|
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
      self_cpu_time_seconds: stat.fetch(:self_cpu_time_seconds),
      children_cpu_time_seconds: stat.fetch(:children_cpu_time_seconds),
      rss_bytes: stat.fetch(:rss_bytes),
      read_io_bytes: io.fetch(:read_io_bytes),
      write_io_bytes: io.fetch(:write_io_bytes)
    }
  end

  def read_stat(process_id)
    raw = File.read(File.join(proc_root, process_id.to_s, "stat"))
    after_name = raw[(raw.rindex(")") + 2)..]
    fields = after_name.split
    {
      pgid: Integer(fields[2]),
      self_cpu_time_seconds: fields.values_at(11, 12).sum { |value| Integer(value) }.to_f / clock_ticks,
      children_cpu_time_seconds: fields.values_at(13, 14).sum { |value| Integer(value) }.to_f / clock_ticks,
      rss_bytes: Integer(fields[21]) * page_size
    }
  rescue Errno::ENOENT, Errno::EACCES, ArgumentError, TypeError
    nil
  end

  def read_io(process_id)
    values = { read_io_bytes: 0, write_io_bytes: 0 }
    File.foreach(File.join(proc_root, process_id.to_s, "io")) do |line|
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
    @clock_ticks ||= Etc.sysconf(Etc::SC_CLK_TCK)
  rescue StandardError
    100
  end

  def page_size
    @page_size ||= Etc.sysconf(Etc::SC_PAGESIZE)
  rescue StandardError
    4096
  end

  def linux?
    RUBY_PLATFORM.include?("linux")
  end
end
