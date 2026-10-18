module Go
  # Parses the native profile written by `go test -coverprofile`. Each Go
  # statement block is projected onto every source line it spans so the result
  # can feed Syrus's line-oriented hit map, changed-line coverage, and reports.
  class CoverageAnalyzer
    SUPPORTED_MODES = %w[set count atomic].freeze
    RECORD_PATTERN = /\A(.+):(\d+)\.(\d+),(\d+)\.(\d+)\s+(\d+)\s+(\d+)\z/

    def self.call(artifact_path:, format_hint: nil)
      return nil unless format_hint.to_s.downcase == "go-cover"

      new(artifact_path.read, artifact_path: artifact_path).parse
    end

    def initialize(content, artifact_path: nil)
      @content = content
      @artifact_path = artifact_path && Pathname.new(artifact_path).expand_path
    end

    def parse
      lines = @content.each_line.to_a
      mode = parse_header(lines.shift)
      hit_map = {}
      coverage_units = {}

      lines.each_with_index do |raw_record, index|
        record = raw_record.strip
        next if record.empty?

        match = RECORD_PATTERN.match(record)
        raise ArgumentError, "invalid Go coverage record on line #{index + 2}: #{record.inspect}" unless match

        path, start_line, start_column, end_line, end_column, statement_count, count = match.captures
        start_line = Integer(start_line)
        start_column = Integer(start_column)
        end_line = Integer(end_line)
        end_column = Integer(end_column)
        statement_count = Integer(statement_count)
        count = Integer(count)
        validate_record!(start_line, start_column, end_line, end_column, statement_count, index + 2)

        normalized_path = normalize_path(path)
        file_lines = (hit_map[normalized_path] ||= {})
        (start_line..end_line).each do |line_number|
          key = line_number.to_s
          file_lines[key] = merge_count(file_lines[key], count, mode)
        end

        units = (coverage_units[normalized_path] ||= {})
        unit_key = "#{start_line}.#{start_column},#{end_line}.#{end_column}"
        unit = (units[unit_key] ||= { statements: statement_count, hits: 0 })
        if unit[:statements] != statement_count
          raise ArgumentError, "conflicting Go coverage statement count on line #{index + 2}"
        end
        unit[:hits] = merge_count(unit[:hits], count, mode)
      end

      build_result(hit_map, coverage_units)
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

    def validate_record!(start_line, start_column, end_line, end_column, statement_count, line_number)
      valid_position = start_line.positive? && start_column.positive? && end_line >= start_line && end_column.positive?
      return if valid_position && statement_count.positive?

      raise ArgumentError, "invalid Go coverage record bounds on line #{line_number}"
    end

    def merge_count(existing, count, mode)
      return count.positive? || existing.to_i.positive? ? 1 : 0 if mode == "set"

      existing.to_i + count
    end

    def normalize_path(path)
      normalized = path.tr("\\", "/")
      module_path, module_root = module_context
      return normalized unless module_path && (normalized == module_path || normalized.start_with?("#{module_path}/"))

      relative = normalized.delete_prefix(module_path).delete_prefix("/")
      module_root.join(relative).to_s
    end

    def module_context
      return @module_context if defined?(@module_context)

      directory = @artifact_path&.dirname
      go_mod = nil
      while directory && directory != directory.parent
        candidate = directory.join("go.mod")
        if candidate.file?
          go_mod = candidate
          break
        end
        directory = directory.parent
      end

      module_name = go_mod&.each_line&.filter_map { |line| line[/\Amodule\s+(\S+)/, 1] }&.first
      @module_context = module_name ? [ module_name, go_mod.dirname ] : [ nil, nil ]
    end

    def build_result(hit_map, coverage_units)
      file_stats = coverage_units.transform_values do |units|
        executable = units.values.sum { |unit| unit[:statements] }
        covered = units.values.select { |unit| unit[:hits].positive? }.sum { |unit| unit[:statements] }
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
          file_stats: file_stats,
          coverage_units: coverage_units
        },
        lines_pct: lf.positive? ? (lh.to_f / lf * 100).round(2) : nil
      )
    end
  end
end
