module CoverageAnalysis
  # Merges multiple coverage hit maps (from different test runs or tools) by
  # summing hit counts per line. Line totals are recomputed from the merged hit
  # map so overlapping sources count each executable line once; branch/function
  # totals are accumulated because the hit map only has line identity.
  module MergeStrategy
    module_function

    # Takes an array of raw hashes (as produced by CoverageAnalysis::Parsers::Base#build_result)
    # and returns a single merged hash in the same shape.
    def merge_all(raws)
      merged_hit_map   = {}
      merged_file_stats = {}
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
        line_count = lines.size
        covered_line_count = lines.count { |_line_num, hits| hits.to_i.positive? }

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
        file_stats: merged_file_stats
      }
    end
  end
end
