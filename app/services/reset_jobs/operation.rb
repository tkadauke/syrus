module ResetJobs
  class Operation
    RESETTABLE_STATES = %w[running failed implemented approved no_change_needed].freeze

    def self.preflight(job)
      return refusal(:landing, slug: job.slug) if job.landing?
      return refusal(:merged, slug: job.slug) if job.closed? && job.closure_reason == "pr_merged"
      return refusal(:merge_train, slug: job.slug) if MergeTrain.active.joins(:members).exists?(merge_train_members: { job_id: job.id })
      children = job.stack_children.where.not(state: Job::TERMINAL_STATES).where("pr_number IS NOT NULL OR branch_name IS NOT NULL")
      return refusal(:stacked_children, slugs: children.map(&:slug).join(", ")) if children.any?
      refusal(:state, slug: job.slug, state: job.state) unless RESETTABLE_STATES.include?(job.state)
    end

    # Refusals are shown to operators in their own language (UI and chat).
    def self.refusal(key, **options)
      I18n.t("reset_jobs.refusals.#{key}", **options)
    end

    def self.destruction_summary(job)
      {
        open_pr_number: job.pr_number,
        branch: job.branch_name,
        checkpoints: RunCheckpoint.where(job: job).count,
        active_workflows: active_workflows(job).map(&:id)
      }.compact
    end

    def self.active_workflows(job)
      WorkUnits::TerminalWorkflowSync.for_job(job)
      owned_ids = WorkUnits::Ownership.active_workflow_ids([ job.id ]).to_a
      direct_ids = job.workflows.where(state: Workflow::OPERATOR_DISMISSABLE_STATES).pluck(:id)
      Workflow.where(id: direct_ids | owned_ids).order(:created_at, :id)
    end

    def initialize(job:, user:, reason:, pending_action: nil)
      @job, @user, @reason, @pending_action = job, user, reason, pending_action
    end

    def call
      raise ArgumentError, self.class.preflight(job) if self.class.preflight(job)
      cancel_and_supersede!
      remove_remote_state!
      remove_local_state!
      restart!
      job.reload
    end

    private

    attr_reader :job, :user, :reason, :pending_action

    def cancel_and_supersede!
      active_units = WorkUnits::Ownership.active_units_for_job(job)
      workflows = self.class.active_workflows(job).to_a
      runs = runs_for_reset(workflows)
      job.spawned_processes.running.find_each { |process| process.request_kill!(user:) }
      workflows.each do |workflow|
        WorkUnits::WorkflowCancellation.cancel!(workflow, reason: Workflow::SUPERSEDED_BY_RESET_REASON, artifacts: reset_artifacts)
      end
      runs.active.find_each do |run|
        run.cancel! if run.may_cancel?
        run.save!
      end
      active_units.each { |unit| unit.preempt!(reason: Workflow::SUPERSEDED_BY_RESET_REASON) }
      job.workflows.find_each { |workflow| workflow.update!(artifacts: workflow.artifacts.to_h.merge(reset_artifacts)) }
      runs.find_each { |run| run.update!(artifacts: run.artifacts.to_h.merge(reset_artifacts)) }
    end

    def runs_for_reset(workflows)
      workflow_step_ids = Step.where(workflow_id: workflows.map(&:id)).select(:id)
      Run.where(job_id: job.id).or(Run.where(step_id: workflow_step_ids))
    end

    def remove_remote_state!
      client = GithubClient.for(repository: job.repository, user: job.user)
      client.close_pull_request(job.repository.slug, job.pr_number) if job.pr_number.present?
      client.delete_branch(job.repository.slug, job.branch_name) if job.branch_name.present?
      RunCheckpoint.where(job: job).find_each { |checkpoint| client.delete_ref(job.repository.slug, checkpoint.remote_ref) }
      RunCheckpoint.where(job: job).destroy_all
    end

    def remove_local_state!
      job.workflows.find_each { |workflow| WorkflowWorkspace.cleanup_for(workflow, force_local: true, actor: "reset_job", reason:) }
    end

    def restart!
      job.with_lock do
        job.update!(pr_number: nil, branch_name: nil, branch_deleted_at: Time.current,
          closure_reason: nil, landed_sha: nil)
        job.reset_from_scratch!
      end
    end

    def reset_artifacts
      { "superseded_by_reset_at" => Time.current.iso8601, "cancelled_reason" => Workflow::SUPERSEDED_BY_RESET_REASON,
        "reset_reason" => reason,
        "reset_actor_type" => user.class.polymorphic_name, "reset_actor_id" => user.id,
        "reset_pending_action_id" => pending_action&.id }.compact
    end
  end
end
