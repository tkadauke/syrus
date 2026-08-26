module Prompts
  # Prompt for the hotfix_sync_repair step (Workflows::HotfixSync). Mirrors
  # Prompts::PromotionRepair: renders the repository's configured
  # `delivery.hotfix_sync.repair_skill` instructions (Skills::Renderer, the
  # same tolerant `{{key}}` substitution Steps::RunSkill uses) and layers on
  # run-specific context about which refs are being synced and whether this
  # run exists because hotfix_sync_assemble hit a merge conflict or because a
  # later `promotion`-phase grade run failed.
  class HotfixSyncRepair
    def initialize(definition:, source_branch:, target_branch:, repo_slug:, conflict:)
      @definition = definition
      @source_branch = source_branch
      @target_branch = target_branch
      @repo_slug = repo_slug
      @conflict = conflict
    end

    def to_s
      [ context_section, skill_instructions ].join("\n\n---\n\n")
    end

    private

    def context_section
      reason = @conflict ? "the deterministic merge attempt hit a conflict" : "the hotfix-sync grade phase failed on the merged branch"
      <<~SECTION.strip
        This is a **hotfix-sync repair** run for `#{@repo_slug}`: syncing the release branch `#{@source_branch}` back into
        the development branch `#{@target_branch}`. You were invoked because #{reason}.

        Your workspace is already checked out on an integration branch based on `#{@target_branch}`'s
        current tip, with `#{@source_branch}` fetched as `origin/#{@source_branch}`.
      SECTION
    end

    def skill_instructions
      Skills::Renderer.render(@definition, { "source_branch" => @source_branch, "target_branch" => @target_branch })
    end
  end
end
