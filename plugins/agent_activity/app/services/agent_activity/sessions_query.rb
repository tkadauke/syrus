module AgentActivity
  # One row per Run whose Step is agentic (Step::AGENTIC_KINDS) -- sessions
  # only, no checks/triggers. `scope: :mine` restricts to Jobs visible via
  # `Job.accessible_to` (direct/Team repository membership plus upstream
  # repositories) or effectively owned by the user (`Job.effectively_owned_by`,
  # app/models/job.rb); `scope: :admin` sees every session on the instance.
  class SessionsQuery
    DEFAULT_PER = 20
    MAX_PER = 100
    COUNT_SAMPLE_LIMIT = 1_000

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
      offset = (@page - 1) * @per

      rows = filtered.includes(step: :workflow, job: :repository)
        .order(started_at: :desc, id: :desc)
        .offset(offset)
        .limit(@per + 1)
        .to_a
      has_more = rows.length > @per
      rows = rows.first(@per)
      total = total_for(filtered, offset: offset, rows_count: rows.length, has_more: has_more)

      {
        rows: rows,
        total: total,
        page: @page,
        per: @per,
        running_count: self.class.capped_count(visible.where(state: "running"))
      }
    end

    def self.count_for_smart_folder(base_scope, folder)
      filter = folder.filter.presence || Filters::Ast.serialize(Filters::Ast::EMPTY)
      ast = Filters::Ast.parse(filter)

      return capped_count(base_scope) if ast == Filters::Ast::EMPTY
      return exact_state_count(base_scope, ast.children.first.value) if single_status_filter?(ast)

      nil
    end

    def self.capped_count(scope, limit: COUNT_SAMPLE_LIMIT)
      ids = scope.reselect(:id).limit(limit + 1).pluck(:id)
      [ ids.size, limit ].min
    end

    def self.single_status_filter?(ast)
      ast.is_a?(Filters::Ast::AndNode) &&
        ast.children.one? &&
        ast.children.first.is_a?(Filters::Ast::Chip) &&
        ast.children.first.field == "status" &&
        ast.children.first.op == "is"
    end
    private_class_method :single_status_filter?

    def self.exact_state_count(scope, state)
      scope.where(state: state).count
    end
    private_class_method :exact_state_count

    private

    def total_for(filtered, offset:, rows_count:, has_more:)
      return filtered.count unless @filter.empty?

      offset + rows_count + (has_more ? 1 : 0)
    end
  end
end
