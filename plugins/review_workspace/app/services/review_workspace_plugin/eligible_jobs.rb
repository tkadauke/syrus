module ReviewWorkspacePlugin
  class EligibleJobs
    def self.call(user:, scope: Syrus::Host::Jobs.all) = new(user:, scope:).call

    def initialize(user:, scope:)
      @user = user
      @scope = scope
    end

    def call
      jobs = candidate_scope.includes(:repository, :epic, dependencies: [ :depends_on_job, :depends_on_epic ]).to_a

      jobs
        .select { |job| approvable_by_user?(job) }
        .sort_by { |job| ordering_key(job) }
    end

    private

    attr_reader :user, :scope

    def candidate_scope
      writable_repository_ids = Syrus::Host::Repositories.writable_by(user).select(:id)
      writable_jobs = Syrus::Host::Jobs.where(user_id: user.id).or(Syrus::Host::Jobs.where(repository_id: writable_repository_ids))
      scoped_writable_jobs = scope.where(id: writable_jobs.select(:id))

      Syrus::Host::Jobs.visible_to(user, scope: scoped_writable_jobs)
        .where(state: "implemented", investigation: false, manual_paused: false, kind: Syrus::Host::Jobs.user_facing_kinds)
    end

    def approvable_by_user?(job)
      job.auto_merge_enabled? && job.may_approve? && job.can_add_job_approval?(user) && !current_approval?(job)
    end

    def current_approval?(job)
      approved_at = approvals_by_job_id[job.id]
      approved_at.present? && (job.approval_withdrawn_at.blank? || approved_at > job.approval_withdrawn_at)
    end

    def approvals_by_job_id
      @approvals_by_job_id ||= Syrus::Host::ActivityRecords.job_approvals.where(user:, job_id: candidate_scope.select(:id)).pluck(:job_id, :approved_at).to_h
    end

    def ordering_key(job)
      [
        job.dependencies_satisfied? ? 0 : 1,
        Syrus::Host::Jobs.priority_rank(job.priority),
        job.finished_at || job.updated_at || job.created_at,
        job.id
      ]
    end
  end
end
