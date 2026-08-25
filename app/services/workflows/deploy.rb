module Workflows
  # Runs the repository's configured `.syrus.yml` `deploy.run` command
  # against this Job's workspace — launched directly on a Job (manual
  # deploy) or by the continuous-deploy auto-trigger, both outside this
  # Job's scope. Modeled as a real Workflow rather than a bespoke
  # side-model so it gets retry-from-failed-step, Run transcripts, the
  # admin repair toolkit, and WorkflowWorkspacePruneJob cleanup for free.
  #
  #   prepare → deploy
  #
  # `prepare` is the same deterministic setup step every other chain
  # uses. `deploy` is entirely non-agentic — there is no LLM turn in
  # this chain at all.
  class Deploy < Base
    steps :prepare, :deploy

    def self.trigger_kind = "deploy"

    def self.agentic? = false

    # Manual deploys run on ordinary Jobs (issue/direct/etc.) whose state
    # this Workflow must not touch — that Job's lifecycle is owned by its
    # own PR/approval flow, independent of whether a deploy happened to
    # succeed. Continuous deploy's synthetic anchor Job (kind: "deploy",
    # see MaybeDeployJob) has no PR and no operator-review step, so close
    # it here the same way Workflows::MainGrader.close_anchor_job! closes
    # its own anchor Job — regardless of whether the deploy succeeded or
    # failed, since failure detail lives on the Workflow/Run, not the Job.
    def self.after_success(workflow) = close_anchor_job!(workflow)
    def self.after_fail(workflow) = close_anchor_job!(workflow)

    private_class_method def self.close_anchor_job!(workflow)
      job = workflow.job
      return unless job.deploy_job?

      StateTransition.with_source("system") do
        job.close_with_reason!(Job::DEPLOY_CLOSURE_REASON) if job.may_close?
      end
    end
  end
end
