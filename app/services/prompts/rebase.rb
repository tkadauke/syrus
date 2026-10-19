module Prompts
  # Prompt for `rebase` Runs. Composes the run-specific context (which PR,
  # which branch, which base) as $ARGUMENTS and delegates the rebase
  # instructions and git safety contract to the
  # `.claude/skills/rebase/SKILL.md` skill file. Keeping instructions in
  # the skill file lets them be tuned without touching Ruby, and makes the
  # skill directly invocable by the operator for debugging.
  class Rebase
    SKILL_FILE = Rails.root.join(".claude/skills/rebase/SKILL.md").freeze

    def initialize(repo_slug:, branch_name:, base_branch:, pr_number:)
      @repo_slug   = repo_slug
      @branch_name = branch_name
      @base_branch = base_branch
      @pr_number   = pr_number
    end

    def to_s
      subject = if @pr_number.present?
        "The pull request `#{@repo_slug}##{@pr_number}` from branch `#{@branch_name}`"
      else
        "The unpublished work on branch `#{@branch_name}` in `#{@repo_slug}`"
      end
      context = <<~CONTEXT.strip
        This is a **rebase** run. #{subject} is being rebased onto `#{@base_branch}` and
        has conflicts that the mechanical rebase could not resolve.
      CONTEXT
      SkillLoader.render(SKILL_FILE, context)
    end
  end
end
