module AgentActivity
  # One row per Run whose Step is agentic (Step::AGENTIC_KINDS) -- sessions
  # only, no checks/triggers. `scope: :mine` restricts to repositories the
  # user belongs to (Current.user.repositories.active) plus Jobs the user
  # effectively owns (Job.effectively_owned_by, app/models/job.rb); `scope:
  # :admin` sees every session on the instance.
  class SessionsQuery
    DEFAULT_PER = 25
    MAX_PER = 100

    def self.call(...) = new(...).call

    def initialize(scope:, user:, filter:, page: 1, per: DEFAULT_PER)
      @visibility_scope = scope
      @user = user
      @filter = filter
      @page = [ page.to_i, 1 ].max
      @per = per.to_i.clamp(1, MAX_PER)
    end

    def call
      visible = visibility_scoped(base_relation)
      filtered = @filter.apply(visible)

      total = filtered.count
      rows = filtered.includes(step: :workflow, job: :repository)
        .order(started_at: :desc, id: :desc)
        .offset((@page - 1) * @per)
        .limit(@per)
        .to_a

      {
        rows: rows,
        total: total,
        page: @page,
        per: @per,
        running_count: visible.where(state: "running").count
      }
    end

    private

    def base_relation
      Run.joins(:step, :job).where(steps: { kind: Step::AGENTIC_KINDS })
    end

    def visibility_scoped(relation)
      return relation if @visibility_scope == :admin

      repo_ids = @user.repositories.active.select(:id)
      owned_job_ids = Job.effectively_owned_by(@user).select(:id)
      relation.where(jobs: { repository_id: repo_ids }).or(relation.where(job_id: owned_job_ids))
    end
  end
end
