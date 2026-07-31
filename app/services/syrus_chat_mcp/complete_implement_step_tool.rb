require "mcp"

module SyrusChatMcp
  # Called by a Coding Mode or Local Mode chat agent after it has committed and
  # pushed the implementation. Releases the coding state and kicks off graders.
  class CompleteImplementStepTool < MCP::Tool
    extend JobLifecycleToolSupport

    tool_name "complete_implement_step"

    description <<~DESC
      Signal that implementation is complete after the chat coding checkout or
      local daemon has committed and pushed changes to the branch. Triggers the
      appropriate handoff workflow for Syrus graders (and PR open if needed).
      Call this only after the working tree is clean and the branch has been
      pushed to the remote.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to hand off." },
        branch_name: {
          type: "string",
          description: "Branch name pushed to the remote. Required for Jobs without an existing PR; replaces the stored branch when supplied for a rerun."
        }
      },
      required: %w[job_id]
    )

    class << self
      def call(job_id:, branch_name: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)
        job, error = find_repository_job(chat_session, job_id)
        return error if error
        normalized_branch = normalize_branch_name(branch_name)

        unless job.coding?
          return SyrusChatMcp.invalid("Job #{job_id} is not in coding state (current: #{job.state}).")
        end
        unless job.linked_chat_id == chat_session.id
          return SyrusChatMcp.invalid("Job #{job_id} is not linked to this chat session.")
        end
        unless chat_session.local? || chat_session.coding?
          return SyrusChatMcp.invalid("complete_implement_step is only available in Coding Mode or Local Mode.")
        end
        if !chat_session.local? && !Feature.coding_mode_enabled?
          return SyrusChatMcp.invalid("Coding Mode is not enabled.")
        end
        if job.pr_number.blank? && normalized_branch.blank?
          return SyrusChatMcp.invalid("branch_name is required for Jobs without an existing PR.")
        end
        if normalized_branch.present? && !valid_branch_name?(normalized_branch)
          return SyrusChatMcp.invalid("branch_name is not a valid branch name.")
        end

        ApplicationRecord.transaction do
          job.branch_name = normalized_branch if normalized_branch.present?
          if chat_session.local?
            job.exit_local_mode!
            job.save!
          else
            unless job.complete_coding_handoff!
              job.errors.add(:base, "could not start coding handoff")
              raise ActiveRecord::RecordInvalid.new(job)
            end
          end
        end

        workflow_class = chat_session.local? ? Workflows::LocalModeHandoff : Workflows::CodingHandoff
        workflow = workflow_class.instantiate(job: job)
        StepDispatcher.start_workflow(workflow)

        SyrusChatMcp.success(
          job_id: job.id,
          job_state: job.reload.state,
          workflow_id: workflow.id,
          message: "Implementation handed off. Graders and PR workflow enqueued (workflow #{workflow.id})."
        )
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      end

      def normalize_branch_name(branch_name)
        branch_name.to_s.strip.presence
      end

      def valid_branch_name?(branch_name)
        return false if branch_name.start_with?("/", "-") || branch_name.end_with?("/", ".")
        return false if branch_name.include?("//") || branch_name.include?("..")
        return false if branch_name.end_with?(".lock")
        return false if branch_name.split("/").any? { |part| part.blank? || part.start_with?(".") }

        !branch_name.match?(/[[:space:]~^:?*\[\\]/)
      end
    end
  end
end
