module MaintenanceTasks
  module Definitions
    class AgentsBackfill < Base
      key "agents_backfill"
      title "Backfill Agent records"
      summary "Creates Agent records for historical Runs, Chats, Design Doc agent runs, and spawned processes."
      category "backfill"
      recurrence "one_off"
      required_role "admin"
      concurrency_key "agents_backfill"
      batch_size 1_000
      max_parallelism 1
      documentation_path Rails.root.join("app/services/maintenance_tasks/docs/agents_backfill.md")

      step "runs", "Create Agent rows for historical Runs", "Every historical Run should have one Agent row."
      step "chats", "Create Agent rows for historical Chats", "Every historical ChatSession should have one Agent row."
      step "design_docs", "Create Agent rows for Design Doc agent runs", "Every DesignDocs::DesignDocAgentRun should have one Agent row when Design Docs is installed."
      step "processes", "Attach spawned processes to Agents", "Historical spawned process rows are linked to the Agent for their Run or ChatSession."

      def estimate_total_units
        missing_run_agents_count +
          missing_chat_agents_count +
          missing_design_doc_agent_run_agents_count +
          unattributed_processes_count
      end

      def pending_reason
        "#{estimate_total_units} historical agent/process record(s) need attribution."
      end

      def perform_batch(task)
        if missing_run_agents_count.positive?
          return backfill_run_agents(task)
        end

        if missing_chat_agents_count.positive?
          return backfill_chat_agents(task)
        end

        if missing_design_doc_agent_run_agents_count.positive?
          return backfill_design_doc_agent_run_agents(task)
        end

        if unattributed_processes_count.positive?
          return backfill_process_agents(task)
        end

        Result.new(done: true, processed: 0, failed: 0, message: "Agent backfill is complete.", level: "info")
      end

      private

      def missing_run_agents_count
        Run.left_outer_joins(:agent).where(agents: { id: nil }).count
      end

      def missing_chat_agents_count
        ChatSession.left_outer_joins(:agent).where(agents: { id: nil }).count
      end

      def missing_design_doc_agent_run_agents_count
        return 0 unless design_doc_agent_run_class

        design_doc_agent_run_class.left_outer_joins(:agent).where(agents: { id: nil }).count
      end

      def unattributed_processes_count
        attachable_processes_count(resumable_type: "Run", foreign_key: "run_id") +
          attachable_processes_count(
            resumable_type: "ChatSession",
            foreign_key: "chat_session_id",
            extra_where: "spawned_processes.run_id IS NULL"
          )
      end

      def backfill_run_agents(task)
        processed = bulk_create_agents_for(Run, task.batch_size)
        task.current_step_key = "runs"
        task.current_step_title = "Create Agent rows for historical Runs"
        Result.new(done: false, processed: processed, failed: 0, message: "Created #{processed} Run Agent row(s).", level: "progress")
      end

      def backfill_chat_agents(task)
        processed = bulk_create_agents_for(ChatSession, task.batch_size)
        task.current_step_key = "chats"
        task.current_step_title = "Create Agent rows for historical Chats"
        Result.new(done: false, processed: processed, failed: 0, message: "Created #{processed} Chat Agent row(s).", level: "progress")
      end

      def backfill_design_doc_agent_run_agents(task)
        processed = bulk_create_agents_for(design_doc_agent_run_class, task.batch_size)
        task.current_step_key = "design_docs"
        task.current_step_title = "Create Agent rows for Design Doc agent runs"
        Result.new(done: false, processed: processed, failed: 0, message: "Created #{processed} Design Doc Agent row(s).", level: "progress")
      end

      def backfill_process_agents(task)
        processed = bulk_attach_process_agents(resumable_type: "Run", foreign_key: "run_id", limit: task.batch_size)

        if processed < task.batch_size
          processed += bulk_attach_process_agents(
            resumable_type: "ChatSession",
            foreign_key: "chat_session_id",
            limit: task.batch_size - processed,
            extra_where: "spawned_processes.run_id IS NULL"
          )
        end

        task.current_step_key = "processes"
        task.current_step_title = "Attach spawned processes to Agents"
        Result.new(done: false, processed: processed, failed: 0, message: "Attached #{processed} spawned process row(s).", level: "progress")
      end

      def bulk_create_agents_for(model_class, limit)
        ids = model_class.left_outer_joins(:agent)
          .where(agents: { id: nil })
          .reorder(:id)
          .limit(limit)
          .pluck(:id)
        return 0 if ids.empty?

        now = Time.current
        rows = ids.map do |id|
          {
            resumable_type: model_class.name,
            resumable_id: id,
            created_at: now,
            updated_at: now
          }
        end
        Agent.insert_all(rows)
        ids.size
      end

      def bulk_attach_process_agents(resumable_type:, foreign_key:, limit:, extra_where: nil)
        return 0 if limit.to_i <= 0

        connection = ActiveRecord::Base.connection
        where_clauses = [
          "spawned_processes.agent_id IS NULL",
          "spawned_processes.#{foreign_key} IS NOT NULL"
        ]
        where_clauses << extra_where if extra_where.present?
        rows = connection.select_all(<<~SQL.squish).to_a
          SELECT spawned_processes.id AS process_id, agents.id AS agent_id
          FROM spawned_processes
          JOIN agents
            ON agents.resumable_type = #{connection.quote(resumable_type)}
           AND agents.resumable_id = spawned_processes.#{foreign_key}
          WHERE #{where_clauses.join(" AND ")}
          ORDER BY spawned_processes.id
          LIMIT #{Integer(limit)}
        SQL
        return 0 if rows.empty?

        ids = rows.map { |row| Integer(row["process_id"]) }
        cases = rows.map do |row|
          "WHEN #{Integer(row["process_id"])} THEN #{Integer(row["agent_id"])}"
        end.join(" ")

        connection.update(<<~SQL.squish)
          UPDATE spawned_processes
          SET agent_id = CASE id #{cases} END,
              updated_at = #{connection.quote(Time.current)}
          WHERE id IN (#{ids.join(",")})
        SQL
      end

      def attachable_processes_count(resumable_type:, foreign_key:, extra_where: nil)
        connection = ActiveRecord::Base.connection
        where_clauses = [
          "spawned_processes.agent_id IS NULL",
          "spawned_processes.#{foreign_key} IS NOT NULL"
        ]
        where_clauses << extra_where if extra_where.present?

        connection.select_value(<<~SQL.squish).to_i
          SELECT COUNT(*)
          FROM spawned_processes
          JOIN agents
            ON agents.resumable_type = #{connection.quote(resumable_type)}
           AND agents.resumable_id = spawned_processes.#{foreign_key}
          WHERE #{where_clauses.join(" AND ")}
        SQL
      end

      def design_doc_agent_run_class
        return @design_doc_agent_run_class if defined?(@design_doc_agent_run_class)

        @design_doc_agent_run_class = "DesignDocs::DesignDocAgentRun".safe_constantize
      end
    end
  end
end
