require "mcp"

module Coworkers
  class ManageScheduleTool < MCP::Tool
    tool_name "manage_coworker_schedule"

    description "List, add, pause, resume, or run the current coworker's own schedules. Scheduled results are posted to the coworker's main chat."

    input_schema(
      properties: {
        action: { type: "string", enum: %w[list add pause resume fire_now] },
        scheduled_task_id: { type: "integer" },
        name: { type: "string" },
        prompt: { type: "string" },
        kind: { type: "string", enum: %w[cron one_shot] },
        schedule_input: { type: "string", description: "Natural cadence or five-field cron expression." },
        fire_at: { type: "string", description: "ISO 8601 time for a one-shot schedule." }
      },
      required: %w[action]
    )

    class << self
      def call(action:, server_context:, scheduled_task_id: nil, name: nil, prompt: nil, kind: "cron", schedule_input: nil, fire_at: nil)
        coworker = current_coworker(server_context)
        return Mcp::Tools.invalid("manage_coworker_schedule is only available from a coworker's main chat") unless coworker

        ScheduleActions.for(action).new(
          coworker, scheduled_task_id:, name:, prompt:, kind:, schedule_input:, fire_at:
        ).call
      rescue ActiveRecord::RecordInvalid => error
        Mcp::Tools.invalid(error.record.errors.full_messages.to_sentence)
      rescue ArgumentError => error
        Mcp::Tools.invalid(error.message)
      end

      private

      def current_coworker(server_context)
        chat = server_context.fetch(:chat_session)
        Coworkers::Chat.includes(:coworker).find_by(chat_session_id: chat.id, role: "main")&.coworker
      end

      def success(coworker, **extra)
        Mcp::Tools.success(
          coworker_id: coworker.id,
          schedules: coworker.schedules.alive.order(:created_at).map do |task|
            { id: task.id, name: task.name, kind: task.kind, state: task.state,
              schedule: task.schedule_explanation || task.fire_at&.iso8601, next_fire_at: task.next_fire_at&.iso8601 }
          end,
          **extra
        )
      end
    end

    module ScheduleActions
      class Base
        def self.for(action)
          { "list" => List, "add" => Add, "pause" => Pause, "resume" => Resume, "fire_now" => FireNow }.fetch(action.to_s)
        rescue KeyError
          raise ArgumentError, "unknown schedule action"
        end

        def initialize(coworker, **attributes)
          @coworker = coworker
          @attributes = attributes
        end

        private

        attr_reader :coworker, :attributes

        def task = coworker.schedules.alive.find(attributes[:scheduled_task_id])
        def success(**extra) = ManageScheduleTool.send(:success, coworker, **extra)
      end

      def self.for(action) = Base.for(action)

      class List < Base
        def call = success
      end

      class Add < Base
        def call
          repository = coworker.workspace_repository
          raise ArgumentError, "workspace repository is unavailable" unless repository
          raise ArgumentError, "repository write access is required" unless RepositoryPolicy.new(coworker.owner_user, repository).write?

          created = coworker.schedules.create!(
            user: coworker.owner_user, repository: repository, name: attributes[:name].to_s.strip,
            prompt: attributes[:prompt].to_s.strip, kind: attributes[:kind], schedule_input: attributes[:schedule_input],
            fire_at: attributes[:fire_at].presence && Time.zone.parse(attributes[:fire_at]),
            pr_pileup_policy: "skip", auto_approve_mode: "never"
          )
          success(changed: created.id)
        end
      end

      class Pause < Base
        def call
          task.pause!(reason: "operator")
          success(changed: task.id)
        end
      end

      class Resume < Base
        def call
          task.resume!
          success(changed: task.id)
        end
      end

      class FireNow < Base
        def call
          result = ScheduledTasks::Fire.new(task).call
          success(changed: task.id, fired: result.fired?, reason: result.reason, job_id: result.job&.id)
        end
      end
    end
  end
end
