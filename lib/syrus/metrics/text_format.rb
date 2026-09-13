module Syrus
  module Metrics
    # Prometheus text exposition format, version 0.0.4.
    #
    # Written out rather than pulled from a gem because the format is small and
    # fully specified, and because the surrounding registry (owners, share
    # flags, plugin prefixes, declare/undeclare on plugin toggle) is ours
    # regardless. Keeping the renderer behind one class is also the seam that
    # lets a StatsD or OTLP output be added later without touching a call site.
    module TextFormat
      CONTENT_TYPE = "text/plain; version=0.0.4; charset=utf-8".freeze

      def self.render(registry)
        lines = []

        registry.definitions.each do |definition|
          instrument = registry.fetch(definition.name, definition.type)
          samples = instrument.samples
          next if samples.empty?

          lines << "# HELP #{definition.name} #{escape_help(definition.comment)}" if definition.comment.present?
          lines << "# TYPE #{definition.name} #{definition.type}"

          case definition.type
          when :histogram then render_histogram(lines, definition, instrument, samples)
          else render_simple(lines, definition, samples)
          end
        end

        "#{lines.join("\n")}\n"
      end

      def self.render_simple(lines, definition, samples)
        samples.each do |labels, value|
          lines << "#{definition.name}#{format_labels(labels)} #{format_value(value)}"
        end
      end

      # A histogram is exposed as three families: cumulative `_bucket` counters
      # (each "observations <= le"), a `_sum`, and a `_count`. The `+Inf` bucket
      # is mandatory and equals the count.
      def self.render_histogram(lines, definition, instrument, samples)
        samples.each do |labels, entry|
          instrument.buckets.each do |bound|
            lines << "#{definition.name}_bucket#{format_labels(labels.merge(le: format_value(bound)))} " \
                     "#{entry[:buckets][bound]}"
          end
          lines << "#{definition.name}_bucket#{format_labels(labels.merge(le: '+Inf'))} #{entry[:count]}"
          lines << "#{definition.name}_sum#{format_labels(labels)} #{format_value(entry[:sum])}"
          lines << "#{definition.name}_count#{format_labels(labels)} #{entry[:count]}"
        end
      end

      def self.format_labels(labels)
        pairs = labels.reject { |_, value| value.nil? }
        return "" if pairs.empty?

        inner = pairs.map { |key, value| "#{key}=\"#{escape_label(value)}\"" }.join(",")
        "{#{inner}}"
      end

      # Integers render without a decimal point so `5` does not become `5.0`;
      # floats keep full precision. Prometheus accepts both, but the former is
      # what every other exporter emits and what a human expects to read.
      def self.format_value(value)
        return value.to_s if value.is_a?(Integer)
        return value.to_i.to_s if value.is_a?(Float) && value.finite? && value == value.to_i

        value.to_s
      end

      def self.escape_label(value)
        value.to_s.gsub("\\", "\\\\\\\\").gsub("\"", "\\\"").gsub("\n", "\\n")
      end

      def self.escape_help(value)
        value.to_s.gsub("\\", "\\\\\\\\").gsub("\n", "\\n")
      end
    end
  end
end
