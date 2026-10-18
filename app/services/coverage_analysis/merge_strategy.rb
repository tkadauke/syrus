module CoverageAnalysis
  # Merges multiple coverage hit maps (from different test runs or tools) by
  # summing hit counts per line. Line totals are recomputed from the merged hit
  # map so overlapping sources count each executable line once; branch/function
  # totals are accumulated because the hit map only has line identity.
  # Parsers whose native coverage unit is not a physical line may additionally
  # provide `coverage_units` keyed by a stable source range, with a weight and
  # hit count. Those units preserve native aggregate percentages while the hit
  # map remains available for changed-line annotation.
  module MergeStrategy
    module_function

    # Takes an array of raw hashes (as produced by CoverageAnalysis::Parsers::Base#build_result)
    # and returns a single merged hash in the same shape.
    def merge_all(raws)
      merged_hit_map   = {}
      merged_file_stats = {}
      merged_coverage_units = {}
      total_brf = total_brh = total_fnf = total_fnh = 0

      raws.each do |raw|
        (raw[:hit_map] || {}).each do |filepath, lines|
          merged_hit_map[filepath] ||= {}
          lines.each do |line_num, hits|
            merged_hit_map[filepath][line_num] = (merged_hit_map[filepath][line_num] || 0) + hits
          end
        end

        (raw[:file_stats] || {}).each do |filepath, stats|
          merged_file_stats[filepath] ||= { lf: 0, lh: 0, brf: 0, brh: 0, fnf: 0, fnh: 0 }
          merged_file_stats[filepath][:lf]  += stats[:lf].to_i
          merged_file_stats[filepath][:lh]  += stats[:lh].to_i
          merged_file_stats[filepath][:brf] += stats[:brf].to_i
          merged_file_stats[filepath][:brh] += stats[:brh].to_i
          merged_file_stats[filepath][:fnf] += stats[:fnf].to_i
          merged_file_stats[filepath][:fnh] += stats[:fnh].to_i
        end

        (raw[:coverage_units] || {}).each do |filepath, units|
          merged_coverage_units[filepath] ||= {}
          units.each do |unit_key, unit|
            existing = merged_coverage_units[filepath][unit_key]
            if existing && existing[:statements].to_i != unit[:statements].to_i
              raise ArgumentError, "conflicting coverage unit weight for #{filepath}:#{unit_key}"
            end
            merged_coverage_units[filepath][unit_key] ||= { statements: unit[:statements].to_i, hits: 0 }
            merged_coverage_units[filepath][unit_key][:hits] += unit[:hits].to_i
          end
        end

        total_brf += raw[:brf].to_i
        total_brh += raw[:brh].to_i
        total_fnf += raw[:fnf].to_i
        total_fnh += raw[:fnh].to_i
      end

      merged_file_stats.each_value do |stats|
        stats[:lf] = 0
        stats[:lh] = 0
      end

      total_lf = total_lh = 0
      merged_hit_map.each do |filepath, lines|
        units = merged_coverage_units[filepath]
        line_count = units ? units.values.sum { |unit| unit[:statements] } : lines.size
        covered_line_count = if units
          units.values.select { |unit| unit[:hits].positive? }.sum { |unit| unit[:statements] }
        else
          lines.count { |_line_num, hits| hits.to_i.positive? }
        end

        merged_file_stats[filepath] ||= { lf: 0, lh: 0, brf: 0, brh: 0, fnf: 0, fnh: 0 }
        merged_file_stats[filepath][:lf] = line_count
        merged_file_stats[filepath][:lh] = covered_line_count

        total_lf += line_count
        total_lh += covered_line_count
      end

      {
        hit_map:    merged_hit_map,
        lf: total_lf, lh: total_lh,
        brf: total_brf, brh: total_brh,
        fnf: total_fnf, fnh: total_fnh,
        file_stats: merged_file_stats,
        coverage_units: merged_coverage_units
      }
    end
  end
end
