module OperatorBriefing
  class ActivityGate
    EXCLUDED_JOB_KINDS = %w[briefing_generate agent_insight main_grader deploy].freeze

    def initialize(user:, repository:, since:)
      @user = user
      @repository = repository
      @since = since
    end

    def activity?
      job_activity? || workflow_activity? || notable_change_activity? || review_finding_activity?
    end

    private

    attr_reader :user, :repository, :since

    def job_activity?
      scope = repository.jobs.where.not(kind: EXCLUDED_JOB_KINDS)
      scope = scope.where("jobs.created_at > :since OR jobs.updated_at > :since OR jobs.finished_at > :since", since: since) if since.present?
      scope.exists?
    end

    def workflow_activity?
      scope = ::Workflow.joins(:job).where(jobs: { repository_id: repository.id }).where.not(jobs: { kind: EXCLUDED_JOB_KINDS })
      scope = scope.where("workflows.created_at > :since OR workflows.updated_at > :since OR workflows.finished_at > :since", since: since) if since.present?
      scope.exists?
    end

    def notable_change_activity?
      scope = WorkflowNotableChange.where(repository: repository)
      scope = scope.where("created_at > ?", since) if since.present?
      scope.exists?
    end

    def review_finding_activity?
      scope = ReviewFinding.joins(workflow: :job).where(jobs: { repository_id: repository.id })
      scope = scope.where("operator_briefing_review_findings.created_at > ?", since) if since.present?
      scope.exists?
    end
  end
end
