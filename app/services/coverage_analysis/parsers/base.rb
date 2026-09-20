module CoverageAnalysis
  module Parsers
    class Base
      ParseResult = Data.define(:raw, :lines_pct)

      def self.parse(content)
        new(content).parse
      end

      def initialize(content)
        @content = content
      end

      def parse
        raise NotImplementedError, "#{self.class.name} must implement #parse"
      end

      private

      # Merges per-file hit lines and stats into the accumulators when the
      # same filename appears more than once within a single report (e.g.
      # multiple Cobertura <class> elements, or multiple LCOV SF: records,
      # sharing one source file). Later occurrences add to earlier ones
      # instead of overwriting them.
      def merge_file_hit_data!(hit_map, file_stats, filename, lines, stats)
        if hit_map.key?(filename)
          hit_map[filename].merge!(lines) { |_line_num, existing, added| existing + added }
          file_stats[filename].merge!(stats) { |_key, existing, added| existing + added }
        else
          hit_map[filename] = lines
          file_stats[filename] = stats
        end
      end

      def build_result(hit_map:, lf:, lh:, brf:, brh:, fnf:, fnh:, file_stats:)
        lines_pct = lf > 0 ? (lh.to_f / lf * 100).round(2) : nil
        raw = {
          hit_map: hit_map,
          lf: lf, lh: lh,
          brf: brf, brh: brh,
          fnf: fnf, fnh: fnh,
          file_stats: file_stats
        }
        ParseResult.new(raw: raw, lines_pct: lines_pct)
      end
    end
  end
end
