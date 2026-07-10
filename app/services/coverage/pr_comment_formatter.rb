module Coverage
  # Formats a coverage artifact into the markdown body for a GitHub PR comment.
  # Used by Steps::CoverageAnalyze (to pre-render and store the body) and by
  # Steps::CoveragePrComment / Steps::PrOpen (to post or update the comment).
  class PrCommentFormatter
    MARKER = "<!-- syrus-coverage -->".freeze

    # Threshold below which a changed-line coverage ratio earns ⚠️ in the
    # per-file table. This is intentionally lower than any configured overall
    # threshold — it is a visual hint, not enforcement.
    CHANGED_LINE_WARN_PCT = 50.0

    def initialize(artifact, plan:)
      @artifact = artifact
      @plan = plan
    end

    # Returns the fully formatted markdown string, or nil when coverage data
    # is unavailable (so callers can skip posting gracefully).
    def format
      return nil if @artifact["coverage_unavailable"]

      lines = [
        MARKER,
        "## Test Coverage Report",
        "",
        summary_table
      ]

      file_rows = changed_file_rows
      if file_rows.any?
        lines << ""
        lines << per_file_details(file_rows)
      end

      lines.join("\n")
    end

    private

    def summary_table
      rows = []
      rows << "| Metric | Value | Threshold | Status |"
      rows << "|--------|-------|-----------|--------|"

      lines_pct = @artifact.dig("summary", "lines_pct")
      rows << summary_row("Lines", lines_pct, @plan.threshold&.lines) if lines_pct

      branches_pct = @artifact.dig("summary", "branches_pct")
      rows << summary_row("Branches", branches_pct, nil) if branches_pct

      pr_delta_pct = @artifact.dig("pr_delta", "pct")
      rows << summary_row("PR delta", pr_delta_pct, @plan.threshold&.pr_lines) if pr_delta_pct

      rows.join("\n")
    end

    def summary_row(label, pct, threshold)
      threshold_str = threshold ? "#{threshold}%" : "—"
      status = threshold ? (pct >= threshold ? "✅" : "❌") : "—"
      "| #{label} | #{format_pct(pct)} | #{threshold_str} | #{status} |"
    end

    def changed_file_rows
      diff_annotations = @artifact["diff_annotations"] || {}
      return [] if diff_annotations.empty?

      diff_annotations.filter_map do |file, annotations|
        covered = annotations.values.count { |v| v == "covered" }
        uncovered = annotations.values.count { |v| v == "uncovered" }
        total = covered + uncovered
        next if total.zero? && covered.zero?

        {
          file:      file,
          lines_pct: @artifact.dig("files", file, "lines_pct"),
          covered:   covered,
          total:     total
        }
      end.sort_by { |r| r[:file] }
    end

    def per_file_details(file_rows)
      lines = []
      lines << "<details>"
      lines << "<summary>Per-file coverage (#{file_rows.size} file#{"s" if file_rows.size != 1} changed)</summary>"
      lines << ""
      lines << "| File | Lines | Changed lines |"
      lines << "|------|-------|---------------|"

      file_rows.each do |row|
        file_pct   = row[:lines_pct] ? format_pct(row[:lines_pct]) : "—"
        changed_pct = row[:total] > 0 ? (row[:covered].to_f / row[:total] * 100) : 0.0
        warn_flag  = row[:total] > 0 && changed_pct < CHANGED_LINE_WARN_PCT ? " ⚠️" : ""
        changed    = "#{row[:covered]}/#{row[:total]} covered#{warn_flag}"
        lines << "| #{row[:file]} | #{file_pct} | #{changed} |"
      end

      lines << "</details>"
      lines.join("\n")
    end

    def format_pct(pct)
      "#{pct.round(1)}%"
    end
  end
end
