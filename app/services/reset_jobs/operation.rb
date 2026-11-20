module ResetJobs
  class Operation
    RESETTABLE_STATES = %w[running failed implemented approved no_change_needed].freeze
    Preflight = Data.define(:code, :message, :options)

    def self.preflight(job)
      preflight_result(job)&.message
    end

    def self.preflight_result(job)
      return Preflight.new(code: :landing, message: "#{job.slug} is landing; cancel or finish landing before reset_job.", options: { slug: job.slug }) if job.landing?
      if job.closed? && job.closure_reason == "pr_merged"
        return Preflight.new(code: :merged, message: "#{job.slug} was merged and cannot be reset; create a new Job instead.", options: { slug: job.slug })
      end
      if MergeTrain.active.joins(:members).exists?(merge_train_members: { job_id: job.id })
        return Preflight.new(code: :merge_train, message: "#{job.slug} is in an active merge train; cancel the merge train before reset_job.", options: { slug: job.slug })
      end
      children = job.stack_children.where.not(state: Job::TERMINAL_STATES).where("pr_number IS NOT NULL OR branch_name IS NOT NULL")
      if children.any?
        child_slugs = children.map(&:slug).join(", ")
        return Preflight.new(code: :stacked_children,
          message: "Live stacked children depend on this branch: #{child_slugs}; reset or land them first.", options: { children: child_slugs })
      end
      unless RESETTABLE_STATES.include?(job.state)
        Preflight.new(code: :state, message: "#{job.slug} cannot be reset from #{job.state}; retry or reopen it first.",
          options: { slug: job.slug, state: job.state })
      end
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
      previous_workflow_ids = job.workflow_ids
      job.with_lock do
        job.update!(pr_number: nil, branch_name: nil, branch_deleted_at: Time.current,
          closure_reason: nil, landed_sha: nil)
        job.reset_from_scratch!
      end
      if job.queued? && job.workflows.where.not(id: previous_workflow_ids).none?
        WorkUnits::Launcher.instantiate(kind: "initial", job: job)
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
