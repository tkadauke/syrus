module Steps
  # First step of CiFailure workflow. Agent gets the failing-checks
  # payload (via Prompts::CiFailure), reads the test output,
  # diagnoses the cause, fixes the code or test, commits.
  #
  # Cross-workflow boundary: NO --resume from prior workflows.
  class AnalyzeAndFix < Base
    def call
      workspace.setup
      run.update!(prompt: compose_prompt) if run.prompt.blank?

      log("invoking agent for analyze_and_fix step (#{workflow.slug}, ci_failure)")
      base_sha = head_sha
      run_agent(prompt: run.prompt)

      commit_agent_changes(job_commit_subject("Fix CI"))
      assert_branch_history_intact!

      diff = diff_against_default
      step_diff = diff_against_sha(base_sha)
      current_head_sha = head_sha

      if step_diff.blank? && (diagnosis = CiRepair::NonActionableDiagnosis.detect(workflow: workflow, run: run))
        workflow.set_artifact!(CiRepair::NonActionableDiagnosis::ARTIFACT_KEY, diagnosis)
        log(
          "[analyze_and_fix] repeated non-actionable main-branch diagnosis; " \
          "ending CI repair loop as #{diagnosis.fetch('outcome')}"
        )
      elsif diff.blank?
        raise NoChangesProduced, "agent produced no changes"
      end

      run.update!(agent_diff: diff, head_sha: current_head_sha, base_sha: base_sha, step_agent_diff: step_diff)
      publish_run_checkpoint!
    end

    private

    def compose_prompt
      issue = job.issue? ? GithubClient.for(repository: repository, user: job.user).fetch_issue(repository.slug, job.issue_number) : job.synthetic_issue
      failed = workflow.artifact("failed_checks") || []
      head_sha = workflow.artifact("head_sha")
      Prompts::CiFailure.new(
        issue: issue,
        pr_number: job.pr_number || job.external_pr_number,
        repo_slug: repository.slug,
        branch_name: job.branch_name,
        head_sha: head_sha,
        failed_checks: failed,
        instructions: workflow.artifact("manual_ci_repair").to_h["instructions"],
        epic: job.epic,
        job: job,
        injected_context: collect_injected_context
      ).to_s
    end
  end
end
