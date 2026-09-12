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
      batch_size 250
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
        SpawnedProcess.where(agent_id: nil).where.not(run_id: nil).count +
          SpawnedProcess.where(agent_id: nil, run_id: nil).where.not(chat_session_id: nil).count
      end

      def backfill_run_agents(task)
        processed = 0
        Run.left_outer_joins(:agent).where(agents: { id: nil }).order(:id).limit(task.batch_size).find_each do |run|
          Agent.find_or_create_for!(run)
          processed += 1
        end
        task.current_step_key = "runs"
        task.current_step_title = "Create Agent rows for historical Runs"
        Result.new(done: false, processed: processed, failed: 0, message: "Created #{processed} Run Agent row(s).", level: "progress")
      end

      def backfill_chat_agents(task)
        processed = 0
        ChatSession.left_outer_joins(:agent).where(agents: { id: nil }).order(:id).limit(task.batch_size).find_each do |chat_session|
          Agent.find_or_create_for!(chat_session)
          processed += 1
        end
        task.current_step_key = "chats"
        task.current_step_title = "Create Agent rows for historical Chats"
        Result.new(done: false, processed: processed, failed: 0, message: "Created #{processed} Chat Agent row(s).", level: "progress")
      end

      def backfill_design_doc_agent_run_agents(task)
        processed = 0
        design_doc_agent_run_class.left_outer_joins(:agent).where(agents: { id: nil }).order(:id).limit(task.batch_size).find_each do |agent_run|
          Agent.find_or_create_for!(agent_run)
          processed += 1
        end
        task.current_step_key = "design_docs"
        task.current_step_title = "Create Agent rows for Design Doc agent runs"
        Result.new(done: false, processed: processed, failed: 0, message: "Created #{processed} Design Doc Agent row(s).", level: "progress")
      end

      def backfill_process_agents(task)
        processed = 0
        scope = SpawnedProcess.where(agent_id: nil).where.not(run_id: nil).order(:id).limit(task.batch_size)
        scope.find_each do |process|
          next unless process.run

          process.update_columns(agent_id: Agent.find_or_create_for!(process.run).id, updated_at: Time.current)
          processed += 1
        end

        if processed < task.batch_size
          SpawnedProcess.where(agent_id: nil, run_id: nil).where.not(chat_session_id: nil).order(:id).limit(task.batch_size - processed).find_each do |process|
            next unless process.chat_session

            process.update_columns(agent_id: Agent.find_or_create_for!(process.chat_session).id, updated_at: Time.current)
            processed += 1
          end
        end

        task.current_step_key = "processes"
        task.current_step_title = "Attach spawned processes to Agents"
        Result.new(done: false, processed: processed, failed: 0, message: "Attached #{processed} spawned process row(s).", level: "progress")
      end

      def design_doc_agent_run_class
        return @design_doc_agent_run_class if defined?(@design_doc_agent_run_class)

        @design_doc_agent_run_class = "DesignDocs::DesignDocAgentRun".safe_constantize
      end
    end
  end
end
