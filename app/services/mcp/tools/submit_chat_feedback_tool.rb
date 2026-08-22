require "mcp"

module Mcp::Tools
  class SubmitChatFeedbackTool < MCP::Tool
    extend ProposalToolSupport
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "submit_chat_feedback"

    description <<~DESC
      Propose operator feedback on a job for confirmation before triggering a new agent workflow that will improve the implementation. Call this only after discussing the feedback with the operator and reaching agreement on what to change. Feedback for a running or queued job is queued until the job reaches an actionable state. Confirmed feedback on an approved job will unapprove it. Use `list_job_workflows` first to confirm there is no active chat_feedback workflow already running.
      Pass `media` to attach a whiteboard snapshot or pasted screenshot to the feedback -- useful for pointing at a visible bug. Call save_canvas first to get a snapshot ID, or use list_chat_media to see available refs.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to improve." },
        feedback: { type: "string", description: "Markdown feedback from the operator, typically 1-5 paragraphs describing what to change." },
        media: {
          type: "array",
          items: { type: "string" },
          description: "Media references to attach to the Job, e.g. \"snapshot:42\" or \"chat_image:123\". Omit if no media is relevant."
        }
      },
      required: %w[job_id feedback]
    )

    class << self
      def call(job_id:, feedback:, server_context:, media: [])
        chat_session = server_context.fetch(:chat_session)
        job_id = Integer(job_id, exception: false)
        return Mcp::Tools.invalid("job_id is required") unless job_id

        feedback = feedback.to_s.strip
        return Mcp::Tools.invalid("feedback is required") if feedback.blank?

        media_refs = normalize_string_list(media)
        media_error = validate_media_refs(chat_session, media_refs)
        return Mcp::Tools.invalid(media_error) if media_error

        job = find_job!(job_id)

        if job.running? || job.queued?
          pending_action = chat_session.pending_actions.create!(
            action: "submit_chat_feedback",
            state: "queued",
            payload: { "job_id" => job.id, "feedback" => feedback, "media" => media_refs },
            requested_by: "agent"
          )

          return Mcp::Tools.success(
            pending_confirmation_id: pending_action.id,
            pending_action_id: pending_action.id,
            state: pending_action.state,
            status: "queued",
            message: "Feedback queued - will appear for your confirmation once #{job.slug} finishes its current run."
          )
        end

        return Mcp::Tools.invalid("#{job.state} jobs are not actionable for chat feedback; the job must be implemented or approved.") unless actionable?(job)
        if active_chat_feedback_workflow?(job)
          return Mcp::Tools.invalid("a chat_feedback workflow is already queued or running for this job")
        end

        pending_action = create_pending_action_for_current_message!(
          server_context,
          chat_session,
          action: "submit_chat_feedback",
          payload: { "job_id" => job.id, "feedback" => feedback, "media" => media_refs },
          requested_by: "agent"
        )

        Mcp::Tools.success(
          pending_confirmation_id: pending_action.id,
          pending_action_id: pending_action.id,
          state: pending_action.state,
          message: "Chat feedback requires operator confirmation."
        )
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end

      private

      def actionable?(job)
        job.implemented? || job.approved?
      end

      def active_chat_feedback_workflow?(job)
        WorkUnits::Ownership.active_for_job_kind?(job, "chat_feedback")
      end

      def validate_media_refs(chat_session, media_refs)
        media_refs.each do |ref|
          unless ChatMediaRef.valid?(ref)
            return "media contains invalid entry '#{ref}'; must be snapshot:ID or chat_image:ID"
          end

          kind, id = ChatMediaRef.split(ref)
          case kind
          when "snapshot"
            return "media contains #{ref} that does not belong to this chat session" unless chat_session.whiteboard_snapshots.exists?(id)
          when "chat_image"
            return "media contains #{ref} that does not belong to this chat session" unless chat_session.attached_repository_documents.exists?(id)
          end
        end

        nil
      end
    end
  end
end
