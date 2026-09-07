module Admin
  # List payload for the operator-facing decision/escalation queue
  # (workflow-engine-v3 B2/C3, JOB backlog "Build the operator-facing
  # decision/escalation queue UI"). `AttentionItem` and its producers
  # (`AttentionItems::Escalator`, `AttentionItems::Triage`) already exist;
  # nothing rendered them for an operator until now.
  #
  # Deliberately a single index payload with every field a row needs
  # (evidence, adjudication, actions) rather than a separate `show` --
  # the queue is small and this is a minimal read-and-act list, not a
  # paginated-detail surface.
  class AttentionItemsPayload
    PER_PAGE = 50
    MAX_PER_PAGE = 100

    def initialize(params: {})
      @params = params
    end

    # Used to re-render a single item after `decide`/`act` mutate it, without
    # re-running the list query.
    def self.render_item(item)
      new.send(:item_json, item)
    end

    def index_json
      rows = relation.offset((page - 1) * per_page).limit(per_page).to_a
      {
        items: rows.map { |item| item_json(item) },
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
        filter: filter_tree
      }
    end

    private

    attr_reader :params

    def relation
      @relation ||= begin
        scope = AttentionItem.includes(:repository, :job, :workflow, :step, :decided_by_user)
        scope = filter_definition.apply(scope, params)
        scope.in_attention_order
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

    def path_for(target_page)
      raw_params = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
      query = raw_params.slice("q", "state", "queue", "urgency", "repository_id", "per_page").merge("page" => target_page).compact_blank
      "/admin/attention_items#{query.present? ? "?#{query.to_query}" : ""}"
    end

    def item_json(item)
      problem = item.problem
      {
        id: item.id,
        problem_code: item.problem_code,
        problem_label: problem.label,
        signature: item.signature,
        title: item.title,
        summary: item.summary,
        queue: item.queue,
        urgency: item.urgency,
        state: item.state,
        resolution: item.resolution,
        reason: item.reason,
        evidence: item.evidence || {},
        adjudication: item.adjudication,
        actions: Array(item.actions).map { |action| action_json(action) },
        repository: repository_json(item.repository),
        job: job_json(item.job),
        workflow: workflow_json(item.workflow, item.job_id),
        step: step_json(item.step),
        decided_by: user_json(item.decided_by_user),
        decided_at: item.decided_at&.iso8601,
        expires_at: item.expires_at&.iso8601,
        created_at: item.created_at.iso8601
      }
    end

    def action_json(action)
      key = action["action_key"].to_s
      payload = action["payload"] || {}
      { action_key: key, label: action["label"], detail: action_detail(key, payload), payload: payload }
    end

    def action_detail(key, payload)
      command = PendingActions.for(key).new(AttentionItems::ActionContext.new(payload: payload))
      command.action_detail
    rescue StandardError
      nil
    end

    def repository_json(repository)
      return nil unless repository

      { id: repository.id, slug: repository.slug, path: "/repositories/#{repository.id}" }
    end

    def job_json(job)
      return nil unless job

      { id: job.id, slug: job.slug, title: job.issue_title.presence || job.title, state: job.state, path: "/jobs/#{job.id}" }
    end

    def workflow_json(workflow, job_id)
      return nil unless workflow

      { id: workflow.id, slug: workflow.slug, trigger_kind: workflow.trigger_kind, state: workflow.state, path: "/jobs/#{job_id}?tab=workflows#workflow-#{workflow.id}" }
    end

    def step_json(step)
      return nil unless step

      { id: step.id, kind: step.kind, state: step.state }
    end

    def user_json(user)
      return nil unless user

      { id: user.id, display_name: user.display_name, email_address: user.email_address }
    end

    def filter_definition
      @filter_definition ||= Admin::EventLogFilterDefinition.define(:attention_items, model: AttentionItem) do
        field :state, label: "State", bucket: :enum, operators: %w[is is_not is_one_of is_none_of],
          column: :state, values: option_values(AttentionItem::STATES), default: "open"
        field :queue, label: "Queue", bucket: :enum, operators: %w[is is_not],
          column: :queue, values: option_values(AttentionItem::QUEUES)
        field :urgency, label: "Urgency", bucket: :enum, operators: %w[is is_not is_one_of is_none_of],
          column: :urgency, values: option_values(AttentionItem::URGENCIES)
        field :repository_id, label: "Repository ID", bucket: :number, operators: %w[is is_not is_set is_unset],
          column: :repository_id, input_mode: "numeric"
      end
    end

    def filter_tree
      @filter_tree ||= filter_definition.filter_tree(params)
    end
  end
end
