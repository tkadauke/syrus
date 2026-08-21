module DependencyAuditReport
  # Formats a dependency_audit artifact into the markdown body for a GitHub
  # PR comment. Used by Steps::DependencyAudit (to pre-render and store the
  # body) and by Steps::DependencyAuditPrComment / Steps::PrOpen (to post or
  # update the comment). Mirrors CoverageReport::PrCommentFormatter's
  # marker+upsert shape.
  class PrCommentFormatter
    MARKER = "<!-- syrus-dependency-audit -->".freeze
    OUTPUT_LINES = 40

    def initialize(artifact)
      @artifact = artifact
    end

    # Returns the fully formatted markdown string, or nil when every scanned
    # ecosystem came back clean — a clean scan is a silent no-op, so callers
    # skip posting gracefully.
    def format
      flagged = Array(@artifact["results"]).reject { |r| r["clean"] }
      return nil if flagged.empty?

      lines = [
        MARKER,
        "## Dependency Vulnerability Scan",
        "",
        "A changed lockfile triggered a dependency audit. Review the findings " \
          "below before merging — this is informational, not a merge blocker."
      ]

      flagged.each do |result|
        lines << ""
        lines << finding_section(result)
      end

      lines.join("\n")
    end

    private

    def finding_section(result)
      [
        "<details>",
        "<summary>#{result['ecosystem']} — <code>#{result['command']}</code> (exit #{result['exit_status']})</summary>",
        "",
        "```",
        truncated_output(result["output_tail"]),
        "```",
        "</details>"
      ].join("\n")
    end

    def truncated_output(output)
      lines = output.to_s.lines
      return output.to_s.strip if lines.size <= OUTPUT_LINES

      "... (truncated)\n" + lines.last(OUTPUT_LINES).join
    end
  end
end
