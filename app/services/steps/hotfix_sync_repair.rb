module Steps
  # Agentic repair step for HotfixSync workflows. Mirrors
  # Steps::PromotionRepair, reused in the same two contexts by the same
  # chain shape (see Workflows::HotfixSync):
  #
  #   - top-level, right after prepare: only reached when
  #     hotfix_sync_assemble's deterministic merge hit a conflict (a clean
  #     merge skips it).
  #   - inside the retry_until grade loop: reached whenever the configured
  #     grade phase graders fail.
  #
  # Either way the contract is the same: resolve whatever is currently
  # broken using the repository's configured
  # `delivery.hotfix_sync.repair_skill` (Skills.for — the same
  # repo-local-override-else-built-in resolution Steps::RunSkill uses),
  # commit the fix, and let the chain continue.
  class HotfixSyncRepair < Base
    def call
      skill_name = repair_skill_name
      raise StepFailed, "hotfix_sync_repair: no delivery.hotfix_sync.repair_skill configured for #{repository.slug}" if skill_name.blank?

      workspace.setup
      resolution = resolve_skill!(skill_name)
      record_provenance!(resolution)

      perform_agentic_change_step(
        log_message: "invoking agent for hotfix_sync_repair step (#{workflow.slug}, skill=#{skill_name.inspect}, source=#{resolution.source})",
        commit_message: "Syrus hotfix sync repair"
      ) do
        run.update!(prompt: compose_prompt(resolution)) if run.prompt.blank?
      end
    end

    private

    def repair_skill_name
      DeliveryPolicy.for(repository: repository).hotfix_sync_repair_skill
    end

    def resolve_skill!(skill_name)
      Skills.for(
        repository: repository,
        name: skill_name,
        user: job.user,
        workspace_path: workspace.path.to_s,
        args: {}
      )
    rescue Skills::NotFoundError, ArgumentError, Skills::SkillMarkdown::ParseError, Skills::ParameterSchema::ParseError => e
      raise StepFailed, "hotfix_sync_repair: could not resolve repair skill #{skill_name.inspect}: #{e.class}: #{e.message}"
    end

    def record_provenance!(resolution)
      run.update!(
        skill_source: resolution.source.to_s,
        skill_resolved_path: resolution.path,
        skill_resolved_class: resolution.klass&.name
      )
    end

    def compose_prompt(resolution)
      prompt = Prompts::HotfixSyncRepair.new(
        definition: resolution.definition,
        source_branch: workflow.artifact("hotfix_sync_source_branch"),
        target_branch: workflow.artifact("hotfix_sync_target_branch"),
        repo_slug: repository.slug,
        conflict: conflict?
      ).to_s

      append_grade_failure_feedback(prompt)
    end

    def conflict?
      result = workflow.artifact("hotfix_sync_assemble_result")
      result.is_a?(Hash) && result["succeeded"] == false
    end
  end
end
