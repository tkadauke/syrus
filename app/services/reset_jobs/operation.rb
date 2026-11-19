module ResetJobs
  class Operation
    RESETTABLE_STATES = %w[running failed implemented approved no_change_needed].freeze

    def self.preflight(job)
      return "#{job.slug} is landing; cancel or finish landing before reset_job." if job.landing?
      return "#{job.slug} was merged and cannot be reset; create a new Job instead." if job.closed? && job.closure_reason == "pr_merged"
      return "#{job.slug} is in an active merge train; cancel the merge train before reset_job." if MergeTrain.active.joins(:members).exists?(merge_train_members: { job_id: job.id })
      children = job.stack_children.where.not(state: Job::TERMINAL_STATES).where("pr_number IS NOT NULL OR branch_name IS NOT NULL")
      return "Live stacked children depend on this branch: #{children.map(&:slug).join(', ')}; reset or land them first." if children.any?
      "#{job.slug} cannot be reset from #{job.state}; retry or reopen it first." unless RESETTABLE_STATES.include?(job.state)
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
      owned_ids = job.active_runtime_workflows.map(&:id)
      job.workflows.where(state: Workflow::OPERATOR_DISMISSABLE_STATES).or(
        job.workflows.where(id: owned_ids)
      ).order(:created_at, :id)
    end

    def initialize(job:, user:, reason:, pending_action:)
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
      job.spawned_processes.running.find_each { |process| process.request_kill!(user:) }
      self.class.active_workflows(job).each do |workflow|
        WorkUnits::WorkflowCancellation.cancel!(workflow, reason: Workflow::SUPERSEDED_BY_RESET_REASON, artifacts: reset_artifacts)
      end
      job.runs.active.find_each do |run|
        run.cancel! if run.may_cancel?
        run.save!
      end
      active_units.each { |unit| unit.preempt!(reason: Workflow::SUPERSEDED_BY_RESET_REASON) }
      job.workflows.find_each { |workflow| workflow.update!(artifacts: workflow.artifacts.to_h.merge(reset_artifacts)) }
      job.runs.find_each { |run| run.update!(artifacts: run.artifacts.to_h.merge(reset_artifacts)) }
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
        "reset_pending_action_id" => pending_action.id }
    end
  end
end
