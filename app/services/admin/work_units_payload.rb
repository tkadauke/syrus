module Admin
  class WorkUnitsPayload
    PER_PAGE = 50
    MAX_PER_PAGE = 100
    SORTS = {
      "requested" => [ "work_intents.requested_at", "work_intents.id" ],
      "kind" => [ "work_intents.kind", "work_intents.requested_at", "work_intents.id" ],
      "state" => [ "work_intents.state", "work_intents.requested_at", "work_intents.id" ],
      "scope" => [ "work_intents.scope_type", "work_intents.scope_id", "work_intents.requested_at", "work_intents.id" ],
      "repository" => [ "work_intents.repository_id", "work_intents.requested_at", "work_intents.id" ]
    }.freeze

    def initialize(params: {})
      @params = params
    end

    def as_json(*)
      rows = relation.offset((page - 1) * per_page).limit(per_page).to_a
      {
        intents: rows.map { |intent| intent_json(intent) },
        pagination: {
          page: page,
          per_page: per_page,
          total: total,
          total_pages: total_pages,
          first_item: rows.empty? ? 0 : ((page - 1) * per_page) + 1,
          last_item: rows.empty? ? 0 : ((page - 1) * per_page) + rows.length,
          previous_path: page > 1 ? path_for(page - 1) : nil,
          next_path: page < total_pages ? path_for(page + 1) : nil
        },
        filter_schema: filter_definition.schema,
        filter: filter_tree,
        filters: filter_definition.flat_filters(params).symbolize_keys.merge(sort: sort, direction: direction),
        settings: {
          show_work_unit_debug: AppSetting.show_work_unit_debug?
        }
      }
    end

    private

    attr_reader :params

    def relation
      @relation ||= begin
        scope = WorkIntent
          .includes(:repository, :source_repository, :target_repository, :actor)
          .preload(work_units: [ :repository, :source_repository, :target_repository, :workflow, { work_unit_members: { job: :repository } } ])
        scope = filter_definition.apply(scope, params).distinct
        sorted_scope(scope)
      end
    end

    def total
      @total ||= relation.except(:order, :limit, :offset).count(:id)
    end

    def total_pages
      [ (total.to_f / per_page).ceil, 1 ].max
    end

    def page
      parsed = params[:page].to_i
      parsed.positive? ? parsed : 1
    end

    def per_page
      parsed = params[:per_page].to_i
      return PER_PAGE unless parsed.positive?

      [ parsed, MAX_PER_PAGE ].min
    end

    def sort
      value = params[:sort].to_s
      SORTS.key?(value) ? value : "requested"
    end

    def direction
      params[:direction].to_s == "asc" ? "asc" : "desc"
    end

    def sorted_scope(scope)
      ordered_columns = SORTS.fetch(sort).map { |column| "#{column} #{direction}" }
      scope.order(Arel.sql(ordered_columns.join(", ")))
    end

    def intent_json(intent)
      units = intent.work_units.sort_by { |unit| [ unit.created_at || Time.zone.at(0), unit.id ] }.reverse
      {
        id: intent.id,
        kind: intent.kind,
        label: definition_label(intent.kind),
        state: intent.state,
        priority: intent.priority,
        scope_type: intent.scope_type,
        scope_id: intent.scope_id,
        delivery_track: intent.delivery_track,
        wait_reason: intent.wait_reason,
        wait_until: intent.wait_until&.iso8601,
        wait_details: intent.wait_details || {},
        requested_at: intent.requested_at&.iso8601,
        satisfied_at: intent.satisfied_at&.iso8601,
        cancelled_at: intent.cancelled_at&.iso8601,
        source_type: intent.source_type,
        source_id: intent.source_id,
        source_ref: intent.source_ref,
        target_ref: intent.target_ref,
        repository: repository_json(intent.repository),
        source_repository: repository_json(intent.source_repository),
        target_repository: repository_json(intent.target_repository),
        actor: user_json(intent.actor),
        jobs: jobs_json(units),
        units: units.map { |unit| unit_json(unit) }
      }
    end

    def unit_json(unit)
      workflow_job = unit.workflow&.job_id
      {
        id: unit.id,
        kind: unit.kind,
        label: definition_label(unit.kind),
        state: unit.state,
        scope_type: unit.scope_type,
        scope_id: unit.scope_id,
        delivery_track: unit.delivery_track,
        blocked_reason: unit.blocked_reason,
        blocked_until: unit.blocked_until&.iso8601,
        blocked_details: unit.blocked_details || {},
        pause_requested: unit.pause_requested,
        preemption_reason: unit.preemption_reason,
        source_ref: unit.source_ref,
        target_ref: unit.target_ref,
        created_at: unit.created_at&.iso8601,
        started_at: unit.started_at&.iso8601,
        finished_at: unit.finished_at&.iso8601,
        repository: repository_json(unit.repository),
        source_repository: repository_json(unit.source_repository),
        target_repository: repository_json(unit.target_repository),
        workflow: unit.workflow ? workflow_json(unit.workflow, workflow_job) : nil,
        members: unit.work_unit_members.map { |member| member_json(member) }
      }
    end

    def member_json(member)
      {
        role: member.role,
        job: job_json(member.job)
      }
    end

    def jobs_json(units)
      units
        .flat_map(&:work_unit_members)
        .map(&:job)
        .compact
        .uniq(&:id)
        .sort_by(&:id)
        .map { |job| job_json(job) }
    end

    def job_json(job)
      return nil unless job

      {
        id: job.id,
        slug: job.slug,
        title: job.issue_title.presence || job.title,
        state: job.state,
        path: "/jobs/#{job.id}"
      }
    end

    def workflow_json(workflow, job_id)
      {
        id: workflow.id,
        slug: workflow.slug,
        trigger_kind: workflow.trigger_kind,
        state: workflow.state,
        path: "/jobs/#{job_id}?tab=workflows#workflow-#{workflow.id}"
      }
    end

    def repository_json(repository)
      return nil unless repository

      {
        id: repository.id,
        slug: repository.slug,
        path: "/repositories/#{repository.id}"
      }
    end

    def user_json(user)
      return nil unless user

      {
        id: user.id,
        display_name: user.display_name,
        email_address: user.email_address
      }
    end

    def definition_label(kind)
      WorkDefinitions.for(kind).label
    rescue WorkDefinitions::UnknownKind
      kind.to_s.humanize
    end

    def path_for(target_page)
      raw_params = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
      query = raw_params.slice("q", "intent_state", "intent_kind", "unit_state", "unit_kind", "scope_type", "repository_id", "job_id", "workflow_id", "per_page", "sort", "direction").merge("page" => target_page).compact_blank
      "/admin/work_units#{query.present? ? "?#{query.to_query}" : ""}"
    end

    def filter_definition
      @filter_definition ||= Admin::EventLogFilterDefinition.define(:work_units, model: WorkIntent) do
        field :intent_state, label: "Intent state", bucket: :enum, operators: %w[is is_not is_one_of is_none_of], column: :state, values: option_values(WorkIntent::STATES)
        field :intent_kind, label: "Intent kind", bucket: :enum, operators: %w[is is_not is_one_of is_none_of], column: :kind, values: option_values(WorkDefinitions.registry.keys.sort)
        field :scope_type, label: "Scope", bucket: :enum, operators: %w[is is_not is_one_of is_none_of], column: :scope_type, values: option_values(%w[job epic repository])
        field :repository_id, label: "Repository ID", bucket: :number, operators: %w[is is_not is_set is_unset], column: :repository_id, input_mode: "numeric"
        field :unit_state, label: "Unit state", bucket: :enum, operators: %w[is is_not is_one_of is_none_of], values: option_values(WorkUnit::STATES) do |scope, op, value|
          Admin::WorkUnitsPayload.apply_joined_filter(scope, op, value, table: :work_units, column: :state)
        end
        field :unit_kind, label: "Unit kind", bucket: :enum, operators: %w[is is_not is_one_of is_none_of], values: option_values(WorkDefinitions.registry.keys.sort) do |scope, op, value|
          Admin::WorkUnitsPayload.apply_joined_filter(scope, op, value, table: :work_units, column: :kind)
        end
        field :job_id, label: "Job ID", bucket: :number, operators: %w[is is_not], input_mode: "numeric" do |scope, op, value|
          ids = scope.joins(work_units: :work_unit_members).where(work_unit_members: { job_id: Integer(value, exception: false) || 0 })
          op.to_s.in?(%w[is equals]) ? ids : scope.where.not(id: ids.select(:id))
        end
        field :workflow_id, label: "Workflow ID", bucket: :number, operators: %w[is is_not is_set is_unset], input_mode: "numeric" do |scope, op, value|
          case op.to_s
          when "is", "equals"
            scope.joins(:work_units).where(work_units: { workflow_id: Integer(value, exception: false) || 0 })
          when "is_not", "not_equals"
            matches = scope.joins(:work_units).where(work_units: { workflow_id: Integer(value, exception: false) || 0 })
            scope.where.not(id: matches.select(:id))
          when "is_set"
            scope.joins(:work_units).where.not(work_units: { workflow_id: nil })
          when "is_unset"
            matches = scope.joins(:work_units).where.not(work_units: { workflow_id: nil })
            scope.where.not(id: matches.select(:id))
          else
            scope
          end
        end
      end
    end

    def filter_tree
      @filter_tree ||= filter_definition.filter_tree(params)
    end

    def self.apply_joined_filter(scope, op, value, table:, column:)
      op = op.to_s
      relation = scope.joins(:work_units)
      case op
      when "is"
        relation.where(table => { column => value.to_s })
      when "is_not"
        matches = relation.where(table => { column => value.to_s })
        scope.where.not(id: matches.select(:id))
      when "is_one_of"
        relation.where(table => { column => Array(value).map(&:to_s) })
      when "is_none_of"
        matches = relation.where(table => { column => Array(value).map(&:to_s) })
        scope.where.not(id: matches.select(:id))
      else
        scope
      end
    end

  end
end
