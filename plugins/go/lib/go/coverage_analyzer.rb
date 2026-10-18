module Go
  # Parses the native profile written by `go test -coverprofile`. Each Go
  # statement block is projected onto every source line it spans so the result
  # can feed Syrus's line-oriented hit map, changed-line coverage, and reports.
  class CoverageAnalyzer
    SUPPORTED_MODES = %w[set count atomic].freeze
    RECORD_PATTERN = /\A(.+):(\d+)\.(\d+),(\d+)\.(\d+)\s+(\d+)\s+(\d+)\z/

    def self.call(artifact_path:, format_hint: nil)
      return nil unless format_hint.to_s.downcase == "go-cover"

      new(artifact_path.read).parse
    end

    def initialize(content)
      @content = content
    end

    def parse
      lines = @content.each_line.to_a
      mode = parse_header(lines.shift)
      hit_map = {}

      lines.each_with_index do |raw_record, index|
        record = raw_record.strip
        next if record.empty?

        match = RECORD_PATTERN.match(record)
        raise ArgumentError, "invalid Go coverage record on line #{index + 2}: #{record.inspect}" unless match

        path, start_line, _start_column, end_line, _end_column, statement_count, count = match.captures
        start_line = Integer(start_line)
        end_line = Integer(end_line)
        statement_count = Integer(statement_count)
        count = Integer(count)
        validate_record!(start_line, end_line, statement_count, index + 2)

        normalized_path = path.tr("\\", "/")
        file_lines = (hit_map[normalized_path] ||= {})
        (start_line..end_line).each do |line_number|
          key = line_number.to_s
          file_lines[key] = merge_count(file_lines[key], count, mode)
        end
      end

      build_result(hit_map)
    end

    private

    def parse_header(raw_header)
      header = raw_header.to_s.strip
      match = /\Amode:\s*(\S+)\z/.match(header)
      raise ArgumentError, "invalid Go coverage profile header: #{header.inspect}" unless match

      mode = match[1]
      return mode if SUPPORTED_MODES.include?(mode)

      raise ArgumentError, "unsupported Go coverage profile mode: #{mode.inspect}"
    end

    def validate_record!(start_line, end_line, statement_count, line_number)
      return if start_line.positive? && end_line >= start_line && statement_count.positive?

      raise ArgumentError, "invalid Go coverage record bounds on line #{line_number}"
    end

    def merge_count(existing, count, mode)
      return count.positive? || existing.to_i.positive? ? 1 : 0 if mode == "set"

      existing.to_i + count
    end

    def build_result(hit_map)
      file_stats = hit_map.transform_values do |file_lines|
        executable = file_lines.size
        covered = file_lines.count { |_line, hits| hits.positive? }
        { lf: executable, lh: covered, brf: 0, brh: 0, fnf: 0, fnh: 0 }
      end
      lf = file_stats.values.sum { |stats| stats[:lf] }
      lh = file_stats.values.sum { |stats| stats[:lh] }

      CoverageAnalysis::Parsers::Base::ParseResult.new(
        raw: {
          hit_map: hit_map,
          lf: lf, lh: lh,
          brf: 0, brh: 0,
          fnf: 0, fnh: 0,
          file_stats: file_stats
        },
        lines_pct: lf.positive? ? (lh.to_f / lf * 100).round(2) : nil
      )
    end
  end
end
