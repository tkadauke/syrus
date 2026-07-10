module Coverage
  # Converts a merged hit map + totals into the summary / files / hit_map
  # triple consumed by Steps::CoverageAnalyze.
  module Normalizer
    module_function

    # Returns a hash with symbol keys:
    #   :hit_map  — { "filepath" => { "1" => 5, "2" => 0 } }
    #   :summary  — { "lines_pct" => Float|nil, "branches_pct" => Float|nil, "functions_pct" => Float|nil }
    #   :files    — { "filepath" => { "lines_pct" => Float|nil, "branches_pct" => Float|nil } }
    def normalize(merged)
      lf = merged[:lf].to_i
      lh = merged[:lh].to_i
      brf = merged[:brf].to_i
      brh = merged[:brh].to_i
      fnf = merged[:fnf].to_i
      fnh = merged[:fnh].to_i

      summary = {
        "lines_pct"     => lf > 0 ? (lh.to_f / lf * 100).round(2) : nil,
        "branches_pct"  => brf > 0 ? (brh.to_f / brf * 100).round(2) : nil,
        "functions_pct" => fnf > 0 ? (fnh.to_f / fnf * 100).round(2) : nil
      }

      files = (merged[:file_stats] || {}).each_with_object({}) do |(filepath, stats), h|
        file_lf = stats[:lf].to_i
        file_lh = stats[:lh].to_i
        file_brf = stats[:brf].to_i
        file_brh = stats[:brh].to_i
        h[filepath] = {
          "lines_pct"    => file_lf > 0 ? (file_lh.to_f / file_lf * 100).round(2) : nil,
          "branches_pct" => file_brf > 0 ? (file_brh.to_f / file_brf * 100).round(2) : nil
        }
      end

      {
        hit_map: merged[:hit_map] || {},
        summary: summary,
        files: files
      }
    end
  end
end
