module CognitiveCoverage
  LineFact = Data.define(:path, :line_number, :last_modified_at, :complexity)
  Engagement = Data.define(:path, :line_number, :engaged_at, :source, :source_sha)
  LineResult = Data.define(:path, :line_number, :state, :last_modified_at, :engaged_at, :source, :complexity)
  Rollup = Data.define(:key, :line_count, :covered_count, :stale_count, :blind_count, :risk_score, :explanations)
  RankedItem = Data.define(:key, :kind, :risk_score, :coverage_state, :explanations, :rollup, :signals)
  Snapshot = Data.define(:repository, :target_sha, :generated_at, :line_results, :files, :subsystems, :repository_rollup, :ranked_items)
end
