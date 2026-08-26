module Steps
  # Agentic repair step for Promotion workflows. Reused in two contexts by
  # the same chain (see Workflows::Promotion):
  #
  #   - top-level, right after prepare: only reached when
  #     promotion_assemble's deterministic merge hit a conflict (a clean
  #     merge skips it).
  #   - inside the retry_until grade loop: reached whenever the configured
  #     `promotion` grade phase graders fail.
  #
  # Either way the contract is the same: resolve whatever is currently
  # broken using the repository's configured `delivery.promotion.repair_skill`
  # (Skills.for — the same repo-local-override-else-built-in resolution
  # Steps::RunSkill uses), commit the fix, and let the chain continue.
  class PromotionRepair < Base
    def call
      skill_name = repair_skill_name
      raise StepFailed, "promotion_repair: no delivery.promotion.repair_skill configured for #{repository.slug}" if skill_name.blank?

      workspace.setup
      resolution = resolve_skill!(skill_name)
      record_provenance!(resolution)

      perform_agentic_change_step(
        log_message: "invoking agent for promotion_repair step (#{workflow.slug}, skill=#{skill_name.inspect}, source=#{resolution.source})",
        commit_message: "Syrus promotion repair"
      ) do
        run.update!(prompt: compose_prompt(resolution)) if run.prompt.blank?
      end
    end

    private

    def repair_skill_name
      DeliveryPolicy.for(repository: repository).promotion_repair_skill
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
      raise StepFailed, "promotion_repair: could not resolve repair skill #{skill_name.inspect}: #{e.class}: #{e.message}"
    end

    def record_provenance!(resolution)
      run.update!(
        skill_source: resolution.source.to_s,
        skill_resolved_path: resolution.path,
        skill_resolved_class: resolution.klass&.name
      )
    end

    def compose_prompt(resolution)
      prompt = Prompts::PromotionRepair.new(
        definition: resolution.definition,
        source_branch: workflow.artifact("promotion_source_branch"),
        target_branch: workflow.artifact("promotion_target_branch"),
        repo_slug: repository.slug,
        conflict: conflict?
      ).to_s

      append_grade_failure_feedback(prompt)
    end

    def conflict?
      result = workflow.artifact("promotion_assemble_result")
      result.is_a?(Hash) && result["succeeded"] == false
    end
  end
end
