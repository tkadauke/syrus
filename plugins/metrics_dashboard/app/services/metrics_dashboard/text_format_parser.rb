module MetricsDashboard
  # Parses the Prometheus text exposition format back into samples.
  #
  # The recorder consumes the *same* output an external Prometheus would scrape,
  # rather than reading the registry directly. That is the point of the design:
  # the built-in charts and a Grafana dashboard read one source, so they cannot
  # disagree about what a number means. It also means this plugin keeps working
  # unchanged when core declares new metrics.
  #
  # Only counters and gauges are kept. Histogram families are skipped, because
  # charting a quantile properly means re-deriving it from buckets, which is a
  # query engine's job and outside what this plugin promises.
  module TextFormatParser
    Sample = Data.define(:metric, :labels, :value)

    HISTOGRAM_SUFFIXES = %w[_bucket _sum _count].freeze
    TYPE_LINE = /\A#\s+TYPE\s+(\S+)\s+(\S+)\s*\z/

    def self.parse(text)
      lines = text.to_s.lines
      histograms = histogram_names(lines)

      lines.filter_map do |line|
        sample = parse_line(line.strip)
        next if sample.nil?
        next if histogram_family?(sample.metric, histograms)

        sample
      end
    end

    # Read from the `# TYPE` declarations rather than guessed from the name.
    # Suffix matching alone is wrong: `syrus_global_queue_ready_count` is a
    # gauge whose name simply ends in `_count`, and dropping it would silently
    # lose four of the queue metrics this dashboard exists to show.
    def self.histogram_names(lines)
      lines.each_with_object(Set.new) do |line, names|
        match = TYPE_LINE.match(line.strip)
        names << match[1] if match && match[2] == "histogram"
      end
    end

    def self.histogram_family?(metric, histograms)
      return true if histograms.include?(metric)

      HISTOGRAM_SUFFIXES.any? do |suffix|
        metric.end_with?(suffix) && histograms.include?(metric.delete_suffix(suffix))
      end
    end

    def self.parse_line(line)
      return if line.empty? || line.start_with?("#")

      name_part, value_part = split_value(line)
      return if name_part.nil?

      value = Float(value_part, exception: false)
      return if value.nil?

      metric, labels = split_labels(name_part)
      return if metric.nil? || metric.empty?

      Sample.new(metric: metric, labels: labels, value: value)
    end

    # The value is whatever follows the last space, so a label value containing
    # a space cannot be mistaken for the boundary.
    def self.split_value(line)
      index = line.rindex(" ")
      return [ nil, nil ] if index.nil?

      [ line[0...index].strip, line[(index + 1)..].strip ]
    end

    def self.split_labels(name_part)
      return [ name_part, {} ] unless name_part.include?("{")

      metric, rest = name_part.split("{", 2)
      [ metric, parse_labels(rest.to_s.sub(/\}\z/, "")) ]
    end

    # Scanned rather than split on "," so an escaped quote or a comma inside a
    # label value does not split the pair.
    def self.parse_labels(inner)
      inner.scan(/([a-zA-Z_][a-zA-Z0-9_]*)="((?:[^"\\]|\\.)*)"/).to_h do |key, value|
        [ key, unescape(value) ]
      end
    end

    def self.unescape(value)
      value.gsub("\\n", "\n").gsub('\\"', '"').gsub("\\\\", "\\")
    end
  end
end
