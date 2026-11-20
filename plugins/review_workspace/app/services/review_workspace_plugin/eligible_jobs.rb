module ReviewWorkspacePlugin
  class EligibleJobs
    PRIORITY_RANK = Job::PRIORITIES.each_with_index.to_h.freeze

    def self.call(user:, scope: Job.all) = new(user:, scope:).call

    def initialize(user:, scope:)
      @user = user
      @scope = scope
    end

    def call
      jobs = candidate_scope.includes(:repository, :epic, dependencies: [ :depends_on_job, :depends_on_epic ]).to_a
      blocking_ids = approval_blocking_job_ids(jobs.map(&:id))

      jobs
        .select { |job| approvable_by_user?(job) && !blocking_ids.include?(job.id) }
        .sort_by { |job| ordering_key(job) }
    end

    private

    attr_reader :user, :scope

    def candidate_scope
      writable_repository_ids = Repository.writable_by(user).select(:id)
      writable_jobs = Job.where(user_id: user.id).or(Job.where(repository_id: writable_repository_ids))
      scoped_writable_jobs = scope.where(id: writable_jobs.select(:id))

      Job.visible_to(user, scope: scoped_writable_jobs)
        .where(state: "implemented", investigation: false, kind: Job::Kind.user_facing_values)
    end

    def approvable_by_user?(job)
      job.auto_merge_enabled? && job.may_approve? && job.can_add_job_approval?(user) && !current_approval?(job)
    end

    def current_approval?(job)
      approved_at = approvals_by_job_id[job.id]
      approved_at.present? && (job.approval_withdrawn_at.blank? || approved_at > job.approval_withdrawn_at)
    end

    def approvals_by_job_id
      @approvals_by_job_id ||= JobApproval.where(user:, job_id: candidate_scope.select(:id)).pluck(:job_id, :approved_at).to_h
    end

    def approval_blocking_job_ids(job_ids)
      return Set.new if job_ids.empty?

      run_ids = Run.active
        .where(job_id: job_ids)
        .where.not(trigger_kind: Workflow::TriggerKind::NON_APPROVAL_BLOCKING_VALUES)
        .distinct
        .pluck(:job_id)

      unit_ids = WorkUnits::Ownership.active_trigger_kind_lists_by_job_id(job_ids).filter_map do |job_id, trigger_kinds|
        job_id if trigger_kinds.any? { |kind| !Workflow::TriggerKind.non_approval_blocking?(kind) }
      end

      Set.new(run_ids + unit_ids)
    end

    def ordering_key(job)
      [
        job.dependencies_satisfied? ? 0 : 1,
        PRIORITY_RANK.fetch(job.priority, PRIORITY_RANK.length),
        job.finished_at || job.updated_at || job.created_at,
        job.id
      ]
    end
  end
end
