module Steps
  # Agentic final pass before auto-merge. Runs on the approved PR
  # branch immediately before graders and the merge API call, so
  # post-rebase or post-review integration failures can be fixed on
  # the exact tree Syrus is about to land.
  class LandingFix < Base
    include MergeTrainStep

    def call
      perform_agentic_change_step(
        log_message: "invoking agent for landing_fix step (#{workflow.slug}, auto_merge)",
        commit_message: "Syrus pre-merge fix"
      ) do
        run.update!(prompt: compose_prompt) if run.prompt.blank?
      end
      preserve_merge_train_repair_head!
    end

    private

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
        job: job
      ).to_s

      append_grade_failure_feedback(prompt)
    end
  end
end
