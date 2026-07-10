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
