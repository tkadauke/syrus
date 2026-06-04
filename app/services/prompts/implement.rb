module Prompts
  # Implement-step prompt for the Initial workflow. Delegates its static
  # instruction text (git safety contract + phased-execution note) to the
  # `.claude/skills/implement/SKILL.md` skill file and injects the
  # run-specific issue content via the $ARGUMENTS placeholder. Keeping the
  # instructions in a skill file lets them be iterated on independently
  # of the Ruby prompt wiring, and makes the skill directly invocable by
  # the operator for debugging or one-off runs.
  class Implement
    SKILL_FILE = Rails.root.join(".claude/skills/implement/SKILL.md").freeze

    def initialize(issue:, issue_comments: [], replay_context: nil)
      @issue = issue
      @issue_comments = issue_comments
      @replay_context = replay_context
    end

    def to_s
      input = [ issue_context ]
      input << comments_context if @issue_comments.present?
      input << "Additional context from the operator:\n\n#{@replay_context}" if @replay_context.present?
      SkillLoader.render(SKILL_FILE, input.join("\n\n"))
    end

    private

    def issue_context
      [
        "Issue title:\n\n#{@issue.title}",
        "Original issue body:\n\n#{@issue.body.presence || '(No issue body provided.)'}"
      ].join("\n\n")
    end

    def comments_context
      [
        "Subsequent issue comments (chronological; later comments may clarify or supersede the original issue body):",
        @issue_comments.map.with_index(1) { |comment, index| render_comment(comment, index) }.join("\n\n")
      ].join("\n\n")
    end

    def render_comment(comment, index)
      author = comment["author"].presence || "unknown"
      created_at = comment["created_at"].presence || "unknown time"
      body = comment["body"].presence || "(No comment body provided.)"

      "Comment #{index} by @#{author} at #{created_at}:\n\n#{body}"
    end
  end
end
