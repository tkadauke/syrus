module Admin
  class ReconcilerActivityPayload
    PER_PAGE = 50
    MAX_PER_PAGE = 100
    SORTS = {
      "time" => [ "work_engine_reconciler_activity_events.occurred_at", "work_engine_reconciler_activity_events.id" ],
      "type" => [ "work_engine_reconciler_activity_events.event_type", "work_engine_reconciler_activity_events.occurred_at", "work_engine_reconciler_activity_events.id" ],
      "context" => [ "work_engine_reconciler_activity_events.job_id", "work_engine_reconciler_activity_events.workflow_id", "work_engine_reconciler_activity_events.run_id", "work_engine_reconciler_activity_events.occurred_at", "work_engine_reconciler_activity_events.id" ],
      "decision" => [ "work_engine_reconciler_activity_events.issue_kind", "work_engine_reconciler_activity_events.repair_action", "work_engine_reconciler_activity_events.repair_status", "work_engine_reconciler_activity_events.occurred_at", "work_engine_reconciler_activity_events.id" ],
      "message" => [ "work_engine_reconciler_activity_events.message", "work_engine_reconciler_activity_events.occurred_at", "work_engine_reconciler_activity_events.id" ],
      "source" => [ "work_engine_reconciler_activity_events.source", "work_engine_reconciler_activity_events.occurred_at", "work_engine_reconciler_activity_events.id" ]
    }.freeze

    def initialize(params: {})
      @params = params
    end

    def as_json(*)
      rows = relation.offset((page - 1) * per_page).limit(per_page).to_a
      {
        events: rows.map { |event| event_json(event) },
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
        filters: filters_payload.merge(sort: sort, direction: direction),
        event_types: WorkEngineReconcilerActivityEvent::EVENT_TYPES
      }
    end

    private

    attr_reader :params

    def relation
      @relation ||= begin
        scope = WorkEngineReconcilerActivityEvent.includes(:job, :workflow, :run)
        scope = filter_definition.apply(scope, params)
        sorted_scope(scope)
      end
    end

    def total
      @total ||= relation.count
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
      SORTS.key?(value) ? value : "time"
    end

    def direction
      params[:direction].to_s == "asc" ? "asc" : "desc"
    end

    def sorted_scope(scope)
      ordered_columns = SORTS.fetch(sort).map do |column|
        "#{column} #{direction}"
      end
      scope.order(Arel.sql(ordered_columns.join(", ")))
    end

    def event_json(event)
      {
        id: event.id,
        event_type: event.event_type,
        severity: event.severity,
        source: event.source,
        message: event.message,
        issue_kind: event.issue_kind,
        repair_action: event.repair_action,
        repair_status: event.repair_status,
        occurred_at: event.occurred_at&.iso8601,
        details: event.details || {},
        job: event.job ? job_json(event.job) : nil,
        workflow: event.workflow ? workflow_json(event.workflow) : nil,
        run: event.run ? run_json(event.run) : nil
      }
    end

    def job_json(job)
      {
        id: job.id,
        slug: job.slug,
        title: job.issue_title,
        path: "/jobs/#{job.id}"
      }
    end

    def workflow_json(workflow)
      {
        id: workflow.id,
        slug: workflow.slug,
        trigger_kind: workflow.trigger_kind,
        state: workflow.state,
        path: "/jobs/#{workflow.job_id}?tab=workflows#workflow-#{workflow.id}"
      }
    end

    def run_json(run)
      {
        id: run.id,
        state: run.state,
        path: "/admin/runs/#{run.id}/transcript"
      }
    end

    def path_for(target_page)
      raw_params = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
      query = raw_params.slice("q", "event_type", "job_id", "workflow_id", "run_id", "per_page", "sort", "direction").merge("page" => target_page).compact_blank
      "/admin/reconciler_activity#{query.present? ? "?#{query.to_query}" : ""}"
    end

    def filter_definition
      Admin::EventLogFilterDefinitions.reconciler_activity
    end

    def filter_tree
      @filter_tree ||= filter_definition.filter_tree(params)
    end

    def filters_payload
      @filters_payload ||= filter_definition.flat_filters(params).symbolize_keys
    end
  end
end
