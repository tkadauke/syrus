module Prompts
  # Prompt for the promotion_repair step (Workflows::Promotion). Renders the
  # repository's configured `delivery.promotion.repair_skill` instructions
  # (Skills::Renderer — the same tolerant `{{key}}` substitution
  # Steps::RunSkill uses, minus formal Skills::ParameterSchema validation:
  # a repair skill is invoked automatically with only ref context, not
  # operator-supplied args, so an unrelated required parameter must not
  # block the repair) and layers on run-specific context: which refs are
  # being promoted, and whether this run exists because promotion_assemble
  # hit a merge conflict or because a later `promotion` grade-phase run
  # failed.
  class PromotionRepair
    def initialize(definition:, source_branch:, target_branch:, repo_slug:, conflict:)
      @definition = definition
      @source_branch = source_branch
      @target_branch = target_branch
      @repo_slug = repo_slug
      @conflict = conflict
    end

    def to_s
      [ context_section, skill_instructions, ShellCommandExecutionContract::TEXT ].join("\n\n---\n\n")
    end

    private

    def context_section
      reason = @conflict ? "the deterministic merge attempt hit a conflict" : "the `promotion` grade phase failed on the merged branch"
      <<~SECTION.strip
        This is a **promotion repair** run for `#{@repo_slug}`: promoting `#{@source_branch}` into
        `#{@target_branch}`. You were invoked because #{reason}.

        Your workspace is already checked out on an integration branch based on `#{@target_branch}`'s
        current tip, with `#{@source_branch}` fetched as `origin/#{@source_branch}`.
      SECTION
    end

    def skill_instructions
      Skills::Renderer.render(@definition, { "source_branch" => @source_branch, "target_branch" => @target_branch })
    end
  end
end
