module CoverageAnalysis
  # Ranks files by combined test-coverage risk: how undercovered a file is,
  # weighted by how often it has recently changed (CoverageAnalysis::
  # ChangeFrequency) rather than raw coverage percentage alone. Surfaced by
  # the read-only Skills::CoverageGapReport skill.
  #
  # A stable, rarely-touched low-coverage file is still real risk (baseline
  # weight 1x), but a low-coverage file under active churn is much higher
  # priority — untested regressions get introduced where code actually
  # changes — so its risk score compounds with every recent commit.
  #
  # Pure and side-effect free; takes plain data structures rather than a
  # CoverageSnapshot/workspace so the ranking logic is directly unit
  # testable against a fixture with known coverage + change-frequency data.
  module RiskRanking
    RankedFile = Data.define(:path, :lines_pct, :branches_pct, :change_count, :risk_score)

    module_function

    # files: { "path" => { "lines_pct" => Float|nil, "branches_pct" => Float|nil } }
    #        — the CoverageAnalysis::Normalizer / CoverageSnapshot#data shape.
    # change_frequency: { "path" => Integer } commit counts in the lookback
    #        window (CoverageAnalysis::ChangeFrequency). A file absent from
    #        this hash is treated as unchanged (0) in the window.
    # limit: cap on the number of ranked files returned (nil = unbounded).
    #
    # A file with no recorded `lines_pct` (present in the coverage report
    # with zero executable lines counted, or otherwise unmeasured) is
    # treated as maximally uncovered (100%) rather than excluded — "no
    # coverage data" is itself the risk signal, not a reason to hide it.
    #
    # Returns an array of RankedFile sorted by risk_score descending, path
    # ascending as a stable tiebreaker.
    def rank(files:, change_frequency: {}, limit: nil)
      ranked = files.map do |path, stats|
        stats = stats || {}
        lines_pct = stats["lines_pct"]
        uncovered_pct = lines_pct.nil? ? 100.0 : (100.0 - lines_pct)
        change_count = change_frequency[path] || 0

        RankedFile.new(
          path: path,
          lines_pct: lines_pct,
          branches_pct: stats["branches_pct"],
          change_count: change_count,
          risk_score: (uncovered_pct * (1 + change_count)).round(2)
        )
      end

      ranked = ranked.sort_by { |f| [ -f.risk_score, f.path ] }
      limit ? ranked.first(limit) : ranked
    end
  end
end
