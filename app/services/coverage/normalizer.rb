module Coverage
  class Normalizer
    def initialize(raw)
      @files = raw[:files] || {}
    end

    def normalize
      {
        summary: compute_summary,
        files: compute_files,
        hit_map: compute_hit_map
      }
    end

    private

    def compute_summary
      total = 0
      covered = 0

      @files.each_value do |file_data|
        file_data[:lines].each_value do |hits|
          total += 1
          covered += 1 if hits > 0
        end
      end

      lines_pct = total > 0 ? (100.0 * covered / total).round(2) : nil
      { lines_pct: lines_pct, covered_lines: covered, total_lines: total }
    end

    def compute_files
      @files.transform_values do |file_data|
        lines = file_data[:lines]
        total = lines.size
        covered = lines.count { |_, hits| hits > 0 }
        lines_pct = total > 0 ? (100.0 * covered / total).round(2) : nil

        branches = file_data[:branches]
        branches_pct = if branches && (branches[:found] || 0) > 0
          (100.0 * branches[:hit] / branches[:found]).round(2)
        end

        { lines_pct: lines_pct, branches_pct: branches_pct }
      end
    end

    def compute_hit_map
      @files.transform_values do |file_data|
        file_data[:lines].transform_keys(&:to_s)
      end
    end
  end
end
