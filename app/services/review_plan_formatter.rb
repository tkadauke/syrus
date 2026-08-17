# Formats a review_plan Workflow artifact into the markdown body for a
# GitHub PR comment. Used by Steps::ReviewPlan to render the agent's
# self-review before posting or updating the comment.
#
# Named at the top level (not nested under a `ReviewPlan` module) to avoid
# colliding with Steps::ReviewPlan — a bare `ReviewPlan` constant referenced
# from inside that class's methods resolves to itself (Steps::ReviewPlan),
# not to a same-named top-level module.
class ReviewPlanFormatter
  MARKER = "<!-- syrus-review-plan -->".freeze

  def initialize(artifact)
    @artifact = artifact
  end

  # Returns the fully formatted markdown string, or nil when there is
  # nothing worth posting (no items) so callers can skip gracefully.
  def format
    items = Array(@artifact["items"])
    return nil if items.empty?

    lines = [
      MARKER,
      "## Self-Review Notes",
      ""
    ]

    summary = @artifact["summary"].to_s.strip
    if summary.present?
      lines << summary
      lines << ""
    end

    items.each { |item| lines << format_item(item) }

    lines.join("\n")
  end

  private

  def format_item(item)
    file = item["file"].to_s
    line = item["line"]
    note = item["note"].to_s
    location = line.present? ? "`#{file}:#{line}`" : "`#{file}`"

    "- #{location} — #{note}"
  end
end
