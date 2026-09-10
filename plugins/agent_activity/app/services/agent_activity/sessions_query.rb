module AgentActivity
  # One row per Run whose Step is agentic (Step::AGENTIC_KINDS) -- sessions
  # only, no checks/triggers. `scope: :mine` restricts to Jobs visible via
  # `Job.accessible_to` (direct/Team repository membership plus upstream
  # repositories) or effectively owned by the user (`Job.effectively_owned_by`,
  # app/models/job.rb); `scope: :admin` sees every session on the instance.
  class SessionsQuery
    DEFAULT_PER = 20
    MAX_PER = 100

    def self.call(...) = new(...).call

    def self.base_relation
      Run.joins(:step, :job).where(steps: { kind: Step::AGENTIC_KINDS })
    end

    def self.visible_relation(scope:, user:)
      return base_relation if scope == :admin

      visible_job_ids = Job.accessible_to(user).or(Job.effectively_owned_by(user)).select(:id)
      base_relation.where(job_id: visible_job_ids)
    end

    def initialize(scope:, user:, filter:, page: 1, per: DEFAULT_PER)
      @visibility_scope = scope
      @user = user
      @filter = filter
      @page = [ page.to_i, 1 ].max
      @per = (per.presence || DEFAULT_PER).to_i.clamp(1, MAX_PER)
    end

    def call
      visible = self.class.visible_relation(scope: @visibility_scope, user: @user)
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

  end
end
