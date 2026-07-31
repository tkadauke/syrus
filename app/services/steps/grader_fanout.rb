module Steps
  # Materializes per-grader Steps from .syrus.yml. Runs after each
  # `implement` (or equivalent) Step inside the workflow's grade
  # loop; inserts one `grader` Step per configured grader between
  # itself and the next Step in the chain (which is the
  # `grader_collect` Step that aggregates the iteration's outcome).
  #
  # Why this exists: the chain is built at workflow-instantiate
  # time, before the workspace exists. The list of graders comes
  # from `.syrus.yml` in the cloned repo, which is only readable
  # AFTER Steps::Prepare runs. So the static chain has a placeholder
  # `grader_fanout` Step that, at execution time, reads the plan
  # and dynamically inserts the actual graders. Each grader Step's
  # definition (name, command, description, required, timeout)
  # is snapshotted onto its Step#details — immutable for that Step,
  # immune to `.syrus.yml` evolution.
  class GraderFanout < Base
    def call
      workspace.setup
      plan = effective_plan(RepoGradePlan.for(workspace.path))
      grader_fingerprint = GraderConclusionCache.fingerprint_for_plan(plan)
      record_plan_source!(plan, grader_fingerprint)
      apply_loop_max_iterations!(plan.max_iterations)

      log("[grader_fanout] source: #{plan.source}")
      log("[grader_fanout] note: #{plan.note}") if plan.note

      if plan.graders.empty?
        log("[grader_fanout] no graders configured — collect Step will pass through")
        return
      end
      log("[grader_fanout] using #{grader_command_variant} grader variants where configured") unless normal_grader_context?

      # Skip graders whose when_files_changed globs don't match this PR's diff.
      files = changed_files
      active_graders, skipped_graders = plan.graders.partition { |g| files_match?(g, files) }
      skipped_graders.each { |g| log("[grader_fanout] skipped #{g.name} (no matching files changed)") }

      if active_graders.empty?
        log("[grader_fanout] all graders skipped — collect Step will pass through")
        return
      end

      # A recorded success for this exact head SHA + grader set short-circuits
      # the re-run. Safe alongside the skip above: the fingerprint is the full
      # plan, so a full-plan success implies the active subset would pass too.
      if (cache_hit = reusable_success(grader_fingerprint))
        workflow.set_artifact!(
          GraderConclusionCache::ARTIFACT_CACHE_HIT_KEY,
          {
            "commit_sha" => cache_hit.commit_sha,
            "grader_fingerprint" => cache_hit.grader_fingerprint,
            "checked_at" => cache_hit.checked_at&.iso8601,
            "conclusion_id" => cache_hit.id
          }.compact
        )
        log("[grader_fanout] reused successful grader conclusion for #{cache_hit.commit_sha.first(7)} - collect Step will pass through")
        return
      end

      materialize_grader_steps!(active_graders)
      log("[grader_fanout] materialized #{active_graders.size} grader Step(s)")
    end

    private

    def changed_files
      GitRunner.new.run("diff", "--name-only", "#{default_branch_ref}...HEAD", chdir: workspace.path.to_s)
        .split("\n").map(&:strip).reject(&:empty?)
    rescue GitRunner::GitError => e
      log("[grader_fanout] warning: could not determine changed files: #{e.message}")
      []
    end

    def files_match?(grader, changed_files)
      return true if grader.when_files_changed.nil? || grader.when_files_changed.empty?
      changed_files.any? do |file|
        grader.when_files_changed.any? { |pattern| File.fnmatch(pattern, file, File::FNM_DOTMATCH) }
      end
    end

    def record_plan_source!(plan, grader_fingerprint)
      workflow.set_artifact!("grade_plan_source", plan.source)
      workflow.set_artifact!(GraderConclusionCache::ARTIFACT_FINGERPRINT_KEY, grader_fingerprint)
      workflow.set_artifact!(GraderConclusionCache::ARTIFACT_HEAD_SHA_KEY, current_head_sha)
    end

    def reusable_success(grader_fingerprint)
      head_sha = current_head_sha
      return nil if head_sha.blank?

      GraderConclusionCache.latest_success(
        repository: repository,
        commit_sha: head_sha,
        grader_fingerprint: grader_fingerprint
      )
    end

    def current_head_sha
      GitRunner.new.run("rev-parse", "HEAD", chdir: workspace.path.to_s).strip
    rescue StandardError => e
      log("[grader_fanout] could not read current HEAD for grader conclusion cache: #{e.message}")
      nil
    end

    def apply_loop_max_iterations!(max_iterations)
      template = Array(workflow.chain_template).map(&:dup)
      loop_node = template.find { |node| loop_node_for_current_step?(node) }
      return unless loop_node

      loop_node["max_iterations"] = max_iterations
      workflow.update!(chain_template: template)
    end

    def loop_node_for_current_step?(node)
      case node["type"]
      when "loop"
        Array(node["steps"]).map(&:to_s).include?(step.kind)
      when "retry_until"
        (Array(node["repair"]).map(&:to_s) + Array(node["check"]).map(&:to_s)).include?(step.kind)
      else
        false
      end
    end

    # Insert one Step per grader between this fanout Step and its
    # current next_step (which is the iteration's grader_collect).
    # Bump positions of everything past the insertion point to
    # make room.
    def materialize_grader_steps!(graders)
      continuation = step.next_step
      insertion_position = step.position + 1
      offset = graders.size

      Step.transaction do
        workflow.steps.where("position >= ?", insertion_position).update_all(
          [ "position = position + ?", offset ]
        )

        new_steps = graders.each_with_index.map do |grader, index|
          Step.create!(
            workflow: workflow,
            kind: "grader",
            position: insertion_position + index,
            iteration: step.iteration,
            loop_id: step.loop_id,
            details: {
              "name" => grader.name,
              "command" => grader.command,
              "standard_command" => grader.metadata["standard_command"],
              "fast_command" => grader.metadata["fast_command"],
              "ci_command" => grader.metadata["ci_command"],
              "command_variant" => grader.metadata["command_variant"],
              "fast_variant" => grader.metadata["fast_variant"],
              "ci_variant" => grader.metadata["ci_variant"],
              "description" => grader.description,
              "required" => grader.required,
              "timeout_minutes" => grader.timeout_minutes,
              "when_files_changed" => grader.when_files_changed,
              "junit_output" => grader.junit_output
            }
          )
        end

        # Chain the new Steps in order and re-link the last one to
        # the original continuation (grader_collect).
        ([ step ] + new_steps).each_cons(2) { |a, b| a.update!(next_step_id: b.id) }
        new_steps.last.update!(next_step_id: continuation&.id)
      end
    end

    def effective_plan(plan)
      LandingGraderPlan.effective(plan, trigger_kind: workflow.trigger_kind, iteration: run.iteration)
    end

    def normal_grader_context?
      grader_command_variant == :normal
    end

    def grader_command_variant
      LandingGraderPlan.variant_for(trigger_kind: workflow.trigger_kind, iteration: run.iteration)
    end

    def fast_grader_context?
      LandingGraderPlan::FAST_TRIGGER_KINDS.include?(workflow.trigger_kind) ||
        (run.iteration.to_i > 1 && LandingGraderPlan::REPEAT_FAST_TRIGGER_KINDS.include?(workflow.trigger_kind))
    end
  end
end
