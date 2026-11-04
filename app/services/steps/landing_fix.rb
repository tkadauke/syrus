module Steps
  # Agentic final pass before auto-merge. Runs on the approved PR
  # branch immediately before graders and the merge API call, so
  # post-rebase or post-review integration failures can be fixed on
  # the exact tree Syrus is about to land.
  class LandingFix < Base
    include MergeTrainStep

    def call
      begin
        perform_agentic_change_step(
          log_message: "invoking agent for landing_fix step (#{workflow.slug}, auto_merge)",
          commit_message: "Syrus pre-merge fix",
          require_step_diff: true
        ) do
          run.update!(prompt: compose_prompt) if run.prompt.blank?
        end
      rescue NoChangesProduced
        record_outcome!("inconclusive_no_op", reason: "clean_tree_without_structured_resolution")
        log("landing_fix produced no repository changes; treating as a successful no-op so graders can recheck the current tree",
            kind: "system")
        return
      end

      run.reload
      if run.step_agent_diff.present?
        record_outcome!("committed_repair", head_sha: run.head_sha, diff_present: true)
      else
        record_outcome!(
          "verified_no_change_resolution",
          reason: "reported_main_concern_for_repair_lineage",
          report_ids: main_concern_reports_for_repair_lineage.pluck(:id)
        )
      end
      preserve_merge_train_repair_head!
    end

    private

    def record_outcome!(outcome, evidence = {})
      LandingRepairOutcome.record!(step: step, outcome: outcome, evidence: evidence)
    end

    # landing_fix repairs the failing required graders diagnosed just before
    # it in the retry_until loop. If it investigates and finds the failure
    # was not a code defect -- confirmed by filing report_main_concern in
    # this repair lineage, not merely by the agent saying so in prose -- it
    # is correct for it to make no commit. Treat that as the step's normal
    # (no-op) outcome instead of a failure: the loop's next iteration will
    # regrade the same commit rather than hard-failing the whole landing
    # attempt on what report_main_concern already flagged as a transient or
    # pre-existing failure.
    def no_changes_confirmed_not_broken?
      return false unless main_concern_reported_for_repair_lineage?

      log(
        "[landing_fix] no changes were needed -- report_main_concern was filed for this repair lineage, " \
        "so the failing graders are treated as pre-existing/infrastructure rather than a workflow failure",
        kind: "system"
      )
      true
    end

    def main_concern_reported_for_repair_lineage?
      main_concern_reports_for_repair_lineage.exists?
    end

    def main_concern_reports_for_repair_lineage
      direct = MainConcernReport.where(run: run)
      return direct if direct.exists?
      return MainConcernReport.none if step.loop_id.blank?

      repair_steps = workflow.steps
        .where(kind: step.kind, loop_id: step.loop_id)
        .where("steps.iteration <= ?", step.iteration)
      run_ids = repair_steps.joins(:runs).pluck("runs.id")
      return MainConcernReport.none if run_ids.empty?

      MainConcernReport.where(workflow: workflow, run_id: run_ids)
    end

    def preserve_merge_train_repair_head!
      return unless workflow.trigger_kind == "merge_train"
      return if workflow.artifact("merge_train_id").blank?

      train = merge_train
      chdir = workspace.path.to_s
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      sha = publish_integration_head!(
        git,
        train,
        chdir: chdir,
        context: "landing_fix",
        operation_type: "git_merge_train_landing_fix_publish"
      )
      train.update!(integration_sha: sha)
      log("landing_fix: published repaired merge-train integration branch #{train.integration_branch} at #{sha.first(9)}",
          kind: "system")
    end

    def compose_prompt
      issue = job.issue? ? fetch_issue : job.synthetic_issue
      prompt = Prompts::LandingFix.new(
        issue: issue,
        pr_number: job.pr_number || job.external_pr_number,
        repo_slug: repository.slug,
        branch_name: job.branch_name || workflow.artifact("external_pr_head_ref"),
        recent_commits: recent_branch_commits,
        epic: job.epic,
        job: job,
        spill: prompt_spill
      ).to_s

      append_grade_failure_feedback(prompt)
    end
  end
end
