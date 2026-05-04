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

    def initialize(issue:, replay_context: nil)
      @issue = issue
      @replay_context = replay_context
    end

    def to_s
      input = [ "#{@issue.title}\n\n#{@issue.body}".strip ]
      input << "Additional context from the operator:\n\n#{@replay_context}" if @replay_context.present?
      SkillLoader.render(SKILL_FILE, input.join("\n\n"))
    end
  end
end
