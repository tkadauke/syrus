require "mcp"

module Mcp::Tools
  class AdminMaintenanceTasksTool < MCP::Tool
    ACTIONS = %w[list read discover start pause resume cancel dismiss].freeze

    tool_name "admin_maintenance_tasks"

    description "List, inspect, discover, and control maintenance tasks such as backfills and index rebuilds. Admin only."

    input_schema(
      properties: {
        action: {
          type: "string",
          description: "Action to perform.",
          enum: ACTIONS
        },
        task_id: {
          type: "integer",
          description: "Maintenance task id. Required for read/start/pause/resume/cancel/dismiss."
        },
        state: {
          type: "string",
          description: "Optional state filter for list."
        },
        limit: {
          type: "integer",
          description: "Maximum tasks to return for list. Defaults to 20."
        }
      },
      required: %w[action]
    )

    class << self
      def call(action:, task_id: nil, state: nil, limit: 20, server_context:)
        return Mcp::Tools.unauthorized("Admin access required") unless admin?(server_context)
        return Mcp::Tools.invalid("unknown action: #{action}") unless ACTIONS.include?(action.to_s)

        case action.to_s
        when "list" then list(state: state, limit: limit)
        when "read" then read(task_id)
        when "discover" then discover
        else mutate(action.to_s, task_id, server_context.fetch(:chat_session).user)
        end
      rescue ActiveRecord::RecordNotFound
        Mcp::Tools.invalid("maintenance task not found")
      rescue ArgumentError, ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.message)
      end

      private

      def admin?(server_context)
        server_context.fetch(:chat_session).user.admin?
      end

      def list(state:, limit:)
        scope = MaintenanceTask.order(updated_at: :desc, id: :desc)
        scope = scope.where(state: state) if state.present?
        Mcp::Tools.success(tasks: scope.limit(normalize_limit(limit)).map { |task| task_payload(task) })
      end

      def read(task_id)
        task = find_task!(task_id)
        Mcp::Tools.success(task: task_payload(task, include_events: true, include_documentation: true))
      end

      def discover
        MaintenanceTasks::Discovery.call
        list(state: nil, limit: 50)
      end

      def mutate(action, task_id, user)
        task = find_task!(task_id)
        MaintenanceTasks::Actions.public_send(action, task, user: user)
        Mcp::Tools.success(task: task_payload(task.reload, include_events: true))
      end

      def find_task!(task_id)
        id = Integer(task_id)
        MaintenanceTask.find(id)
      rescue ArgumentError, TypeError
        raise ArgumentError, "task_id is required and must be an integer"
      end

      def normalize_limit(limit)
        Integer(limit || 20).clamp(1, 100)
      rescue ArgumentError, TypeError
        20
      end

      def task_payload(task, include_events: false, include_documentation: false)
        payload = App::MaintenanceTasksPayload.serialize_task(task, include_documentation: include_documentation)
        if include_events
          payload[:events] = task.events.order(created_at: :desc, id: :desc).limit(50).map { |event| App::MaintenanceTasksPayload.serialize_event(event) }
        end
        payload
      end
    end
  end
end
