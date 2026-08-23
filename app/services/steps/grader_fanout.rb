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
      log("[grader_fanout] using #{grader_phase} grader phase") unless review_grader_context?

      # Skip graders whose when_files_changed globs don't match this PR's diff.
      files = changed_files
      record_changed_files!(files)
      matching_files = matching_files_for(files)
      active_graders, skipped_graders = plan.graders.partition { |g| files_match?(g, matching_files) }
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

      if materialized_grader_steps.exists?
        log("[grader_fanout] grader Steps already materialized for iteration #{step.iteration}; reusing existing Step chain")
        return
      end

      materialize_grader_steps!(active_graders)
      log("[grader_fanout] materialized #{active_graders.size} grader Step(s)")
    end

    private

    def changed_files
      GitRunner.new.run("diff", "--name-only", "#{changed_files_base_ref}...HEAD", chdir: workspace.path.to_s)
        .split("\n").map(&:strip).reject(&:empty?)
    rescue GitRunner::GitError => e
      log("[grader_fanout] warning: could not determine changed files: #{e.message}")
      []
    end

    def changed_files_base_ref
      return workflow.artifact("predicted_base_sha").presence if workflow.work_definition.landing_validation_child?

      default_branch_ref
    end

    def files_match?(grader, changed_files)
      return true if grader.when_files_changed.nil? || grader.when_files_changed.empty?
      changed_files.any? do |file|
        grader.when_files_changed.any? { |pattern| File.fnmatch(pattern, file, File::FNM_DOTMATCH) }
      end
    end

    # Expands the raw diff's changed files with any :affected_test_analyzer
    # answers before when_files_changed matching. This set is ONLY used for
    # the match decision below — never for record_changed_files!, which must
    # stay a literal diff so its fingerprint stays comparable with the plain
    # `git diff --name-only` fingerprints other landing-validation-cache call
    # sites compute. Strictly additive: a registered analyzer can only turn a
    # would-be skip into a run, never the reverse, so an unregistered,
    # declining, or erroring analyzer leaves matching identical to glob-only
    # behavior against the raw diff.
    def matching_files_for(files)
      return files if files.empty?

      extra = affected_test_files(files)
      extra.empty? ? files : (files + extra).uniq
    end

    def affected_test_files(files)
      Syrus::PluginRegistry.providers_for(:affected_test_analyzer).flat_map do |analyzer|
        begin
          result = analyzer.affected_files(repo_path: workspace.path.to_s, changed_files: files)
          if result.nil?
            log("[grader_fanout] #{analyzer} declined to analyze this diff — falling back to glob-only for it")
            []
          else
            log("[grader_fanout] #{analyzer} reports #{result.size} additional affected file(s)") if result.any?
            Array(result)
          end
        rescue StandardError => e
          log("[grader_fanout] affected_test_analyzer #{analyzer} raised #{e.class}: #{e.message} — falling back to glob-only for it")
          []
        end
      end.uniq
    end

    def record_plan_source!(plan, grader_fingerprint)
      workflow.set_artifact!("grade_plan_source", plan.source)
      workflow.set_artifact!(GraderConclusionCache::ARTIFACT_FINGERPRINT_KEY, grader_fingerprint)
      workflow.set_artifact!(GraderConclusionCache::ARTIFACT_HEAD_SHA_KEY, current_head_sha)
    end

    def record_changed_files!(files)
      normalized = Array(files).map(&:to_s).sort
      workflow.set_artifact!("grade_plan_changed_files", normalized)
      workflow.set_artifact!("grade_plan_changed_files_fingerprint", LandingValidationCache.changed_files_fingerprint(normalized))
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
              "phase" => grader.metadata["phase"],
              "configured_phases" => grader.metadata["configured_phases"],
              "legacy_ci_command" => grader.metadata["legacy_ci_command"],
              "legacy_source_grader" => grader.metadata["legacy_source_grader"],
              "description" => grader.description,
              "required" => grader.required,
              "timeout_minutes" => grader.timeout_minutes,
              "when_files_changed" => grader.when_files_changed,
              "junit_output" => grader.junit_output,
              "failures" => grader.failures
            }
          )
        end

        # Chain the new Steps in order and re-link the last one to
        # the original continuation (grader_collect).
        ([ step ] + new_steps).each_cons(2) { |a, b| a.update!(next_step_id: b.id) }
        new_steps.last.update!(next_step_id: continuation&.id)
      end
    end

    def materialized_grader_steps
      workflow.steps
        .where(kind: "grader", iteration: step.iteration, loop_id: step.loop_id)
        .where("position > ?", step.position)
    end

    def effective_plan(plan)
      LandingGraderPlan.effective(plan, trigger_kind: workflow.trigger_kind, iteration: run.iteration)
    end

    def review_grader_context?
      grader_phase == :review
    end

    def grader_phase
      LandingGraderPlan.phase_for(trigger_kind: workflow.trigger_kind, iteration: run.iteration)
    end
  end
end
