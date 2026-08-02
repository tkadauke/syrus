module Steps
  # Non-agentic incremental rebase for an Epic merge-train that failed at
  # merge_train_land because the base branch moved. Tries a mechanical
  # `git rebase FETCH_HEAD` of the integration branch onto the new base tip.
  #
  # Success path: records the new base SHA so the following
  # merge_train_land_after_rebase sees a fresh base match, and updates
  # MergeTrain#integration_sha for grader context.
  #
  # Failure path (rebase conflict): aborts and raises StepFailed with a
  # "rebuild required" message so MergeTrainFailureHandler falls back to
  # a full merge_train rebuild via LandingFailureHandler#defer_landing!.
  class MergeTrainRebase < Base
    include MergeTrainStep

    def call
      train = merge_train
      client = GithubClient.for(repository: repository, user: job.user)
      push_url = repository.authenticated_push_url(client.access_token)

      workspace.setup
      chdir = workspace.path.to_s
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })

      log("merge_train_rebase: fetching #{train.base_branch} to find new base tip")
      git.run("fetch", push_url, "refs/heads/#{train.base_branch}", chdir: chdir)
      new_base_sha = git.run("rev-parse", "FETCH_HEAD", chdir: chdir).strip

      old_base_sha = workflow.artifact(MergeTrainLand::BASE_SHA_ARTIFACT).to_s
      log("merge_train_rebase: rebasing integration branch #{train.integration_branch} " \
          "onto #{train.base_branch}@#{new_base_sha.first(9)} (was #{old_base_sha.first(9)})")

      begin
        git.run("rebase", "FETCH_HEAD", chdir: chdir)
      rescue GitRunner::GitError => e
        abort_rebase!(git, chdir)
        raise_rebuild_needed!(train, old_base_sha, new_base_sha,
          "incremental rebase of #{train.integration_branch} conflicted: #{e.message.truncate(200)}")
      end

      new_integration_sha = git.run("rev-parse", "HEAD", chdir: chdir).strip
      tree_sha = git.run("rev-parse", "HEAD^{tree}", chdir: chdir).to_s.strip.presence
      workflow.set_artifact!(MergeTrainLand::BASE_SHA_ARTIFACT, new_base_sha)
      train.update!(integration_sha: new_integration_sha)

      log("merge_train_rebase: rebased #{train.integration_branch} to " \
          "#{new_integration_sha.first(9)} (new base #{new_base_sha.first(9)})")
      carry_forward_landing_validation!(git, chdir, train, head_sha: new_integration_sha, tree_sha: tree_sha, base_sha: new_base_sha)
    end

    private

    def carry_forward_landing_validation!(git, chdir, train, head_sha:, tree_sha:, base_sha:)
      return unless repository.trust_clean_rebase_grade?

      grader_fingerprint = current_landing_grader_fingerprint
      changed_files_fingerprint = current_changed_files_fingerprint(git, chdir, base_sha)
      source = LandingValidationCache.carry_forward_source_for(
        job: job,
        base_ref: train.base_branch,
        grader_fingerprint: grader_fingerprint,
        changed_files_fingerprint: changed_files_fingerprint
      )
      unless source.reusable?
        log("merge_train_rebase: did not carry green grade across clean rebase - #{source.reason}", kind: "system")
        return
      end

      LandingValidationCache.record!(
        workflow: workflow,
        head_sha: head_sha,
        tree_sha: tree_sha,
        base_sha: base_sha,
        base_ref: train.base_branch,
        grader_fingerprint: grader_fingerprint,
        changed_files_fingerprint: changed_files_fingerprint,
        validation_source: "clean_rebase"
      )
      LandingThroughputMetrics.record_validation_decision!(
        workflow: workflow,
        decision: LandingValidationCache::Decision.new(
          true,
          source.reason,
          "clean_rebase_carry_forward",
          source.artifact,
          source.workflow
        ),
        context: "merge_train_rebase",
        head_sha: head_sha,
        base_sha: base_sha
      )
      skip_revalidated_grade_steps!(head_sha, source)
    end

    def current_landing_grader_fingerprint
      plan = RepoGradePlan.for(workspace.path)
      plan = LandingGraderPlan.landing(plan)
      GraderConclusionCache.fingerprint_for_plan(plan)
    rescue StandardError => e
      log("merge_train_rebase: could not fingerprint current landing graders for carry-forward: #{e.message}", kind: "system")
      nil
    end

    def current_changed_files_fingerprint(git, chdir, base_sha)
      files = git.run("diff", "--name-only", "#{base_sha}...HEAD", chdir: chdir)
        .split("\n").map(&:strip).reject(&:empty?)
      LandingValidationCache.changed_files_fingerprint(files)
    rescue StandardError => e
      log("merge_train_rebase: could not fingerprint current changed-file selection for carry-forward: #{e.message}", kind: "system")
      nil
    end

    def skip_revalidated_grade_steps!(sha, source)
      log("merge_train_rebase: carried green grade across clean rebase (#{repository.slug}: trust_clean_rebase_grade, #{source.reason}); next landing will skip re-grading head #{sha.first(7)}", kind: "system")
      Step.suppress_cancel_cascade do
        cursor = step.next_step
        while cursor && cursor.kind != "merge_train_land_after_rebase"
          if cursor.may_cancel?
            cursor.cancellation_reason = "landing_validation_cached"
            cursor.cancel!
            cursor.save!
          end
          cursor = cursor.next_step
        end
      end
    end

    def abort_rebase!(git, chdir)
      git.run("rebase", "--abort", chdir: chdir)
    rescue GitRunner::GitError
      nil
    end

    def raise_rebuild_needed!(train, old_base_sha, new_base_sha, detail)
      # Update the stale-base artifact so MergeTrainFailureHandler can
      # reconstruct the "base moved; rebuild required" reason string that
      # LandingFailureHandler recognises as merge_train_rebuild_required?.
      workflow.set_artifact!(
        MergeTrainLand::STALE_BASE_ARTIFACT,
        {
          "base_branch" => train.base_branch,
          "built_base_sha" => old_base_sha.presence,
          "current_base_sha" => new_base_sha,
          "reason" => "base_moved"
        }
      )
      raise StepFailed,
            "#{MergeTrainLand::STALE_BASE_FAILURE_PREFIX} from #{old_base_sha.first(12)} to " \
            "#{new_base_sha.first(12)}; rebuild required (#{detail})"
    end
  end
end
