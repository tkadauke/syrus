module Coverage
  # Result of parsing one coverage artifact file.
  # `raw` is the normalized hit map + totals hash passed to MergeStrategy.
  # Shape of raw:
  #   {
  #     hit_map:    { "filepath" => { "1" => 5, "2" => 0 } },
  #     lf: total_lines_found, lh: total_lines_hit,
  #     brf: branches_found,   brh: branches_hit,
  #     fnf: functions_found,  fnh: functions_hit,
  #     file_stats: { "filepath" => { lf:, lh:, brf:, brh:, fnf:, fnh: } }
  #   }
  ParsedSource = Data.define(:artifact, :format, :found, :raw, :lines_pct)
end
