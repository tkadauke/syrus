module AgentActivity
  # One row per Agent with at least one spawned agent process. Workflow-backed
  # Agents keep Job.accessible_to/effectively_owned_by scoping; chat-backed
  # Agents are always self-scoped to the requesting user, including on the
  # admin page; design-doc-backed Agents use DesignDoc.visible_to.
  class SessionsQuery
    DEFAULT_PER = 20
    MAX_PER = 100

    def self.call(...) = new(...).call

    def self.base_relation
      Agent
        .where(agent_process_exists_sql)
    end

    def self.visible_relation(scope:, user:)
      relation = base_relation
      return relation.where(admin_visibility_sql(user)) if scope == :admin

      visible_job_ids = Job.accessible_to(user).or(Job.effectively_owned_by(user)).select(:id)
      relation.where(operator_visibility_sql(user, visible_job_ids))
    end

    def self.latest_process_started_sql
      "(
        SELECT MAX(spawned_processes.started_at)
        FROM spawned_processes
        WHERE spawned_processes.agent_id = agents.id
          AND spawned_processes.kind = 'agent'
      )"
    end

    def self.agent_process_exists_sql
      "EXISTS (
        SELECT 1
        FROM spawned_processes
        WHERE spawned_processes.agent_id = agents.id
          AND spawned_processes.kind = 'agent'
      )"
    end

    def self.running_process_exists_sql
      "EXISTS (
        SELECT 1
        FROM spawned_processes
        WHERE spawned_processes.agent_id = agents.id
          AND spawned_processes.kind = 'agent'
          AND spawned_processes.finished_at IS NULL
      )"
    end

    def self.latest_process_outcome_sql
      "(
        SELECT latest_sp.outcome
        FROM spawned_processes latest_sp
        WHERE latest_sp.agent_id = agents.id
          AND latest_sp.kind = 'agent'
        ORDER BY latest_sp.started_at DESC, latest_sp.id DESC
        LIMIT 1
      )"
    end

    def self.workflow_agent_sql(visible_job_ids)
      sanitize_sql([
        "(
          agents.resumable_type = 'Run'
          AND EXISTS (
            SELECT 1
            FROM runs
            INNER JOIN steps ON steps.id = runs.step_id
            WHERE runs.id = agents.resumable_id
              AND runs.job_id IN (?)
              AND steps.kind IN (?)
          )
        )",
        visible_job_ids,
        Step::AGENTIC_KINDS
      ])
    end

    def self.chat_agent_sql(user)
      sanitize_sql([
        "(
          agents.resumable_type = 'ChatSession'
          AND EXISTS (
            SELECT 1
            FROM chat_sessions
            WHERE chat_sessions.id = agents.resumable_id
              AND chat_sessions.user_id = ?
          )
        )",
        user.id
      ])
    end

    def self.design_doc_agent_sql(user)
      sanitize_sql([
        "(
          agents.resumable_type = 'DesignDocs::DesignDocAgentRun'
          AND EXISTS (
            SELECT 1
            FROM design_doc_agent_runs
            INNER JOIN design_docs
              ON design_docs.id = design_doc_agent_runs.design_doc_id
            WHERE design_doc_agent_runs.id = agents.resumable_id
              AND (
                design_docs.owner_user_id = ?
                OR EXISTS (
                  SELECT 1
                  FROM design_doc_collaborators
                  WHERE design_doc_collaborators.design_doc_id = design_docs.id
                    AND design_doc_collaborators.user_id = ?
                )
                OR (
                  design_docs.visibility = 'public'
                  AND EXISTS (
                    SELECT 1
                    FROM design_doc_repositories
                    WHERE design_doc_repositories.design_doc_id = design_docs.id
                      AND design_doc_repositories.repository_id IN (?)
                  )
                )
              )
          )
        )",
        user.id,
        user.id,
        Repository.accessible_to(user).select(:id)
      ])
    end

    def self.operator_visibility_sql(user, visible_job_ids)
      [ workflow_agent_sql(visible_job_ids), chat_agent_sql(user), design_doc_agent_sql(user) ].join(" OR ")
    end

    def self.admin_visibility_sql(user)
      [ workflow_admin_agent_sql, chat_agent_sql(user), design_doc_admin_agent_sql ].join(" OR ")
    end

    def self.workflow_admin_agent_sql
      sanitize_sql([
        "(
          agents.resumable_type = 'Run'
          AND EXISTS (
            SELECT 1
            FROM runs
            INNER JOIN steps ON steps.id = runs.step_id
            WHERE runs.id = agents.resumable_id
              AND steps.kind IN (?)
          )
        )",
        Step::AGENTIC_KINDS
      ])
    end

    def self.design_doc_admin_agent_sql
      "agents.resumable_type = 'DesignDocs::DesignDocAgentRun'"
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

      total = filtered.except(:select, :order).count
      rows = filtered
        .includes(:resumable, :spawned_processes)
        .order(Arel.sql("#{self.class.latest_process_started_sql} DESC"), id: :desc)
        .offset((@page - 1) * @per)
        .limit(@per)
        .to_a
      preload_resumable_context(rows)

      {
        rows: rows,
        total: total,
        page: @page,
        per: @per,
        running_count: visible.where(self.class.running_process_exists_sql).except(:select, :order).count
      }
    end

    def self.sanitize_sql(array)
      ActiveRecord::Base.sanitize_sql_array(array)
    end
    private_class_method :sanitize_sql

    def preload_resumable_context(agents)
      resumables_by_type = agents.group_by(&:resumable_type).transform_values { |rows| rows.map(&:resumable).compact }
      preload(resumables_by_type["Run"], [ { job: :repository }, { step: :workflow } ])
      preload(resumables_by_type["ChatSession"], [ { repository_attachments: :attachable } ])
      preload(resumables_by_type["DesignDocs::DesignDocAgentRun"], [ { design_doc: :repositories }, :thread ])
    end

    def preload(records, associations)
      return if records.blank?

      ActiveRecord::Associations::Preloader.new(records: records, associations: associations).call
    end

  end
end
