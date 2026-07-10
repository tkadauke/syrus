require "mcp"

module SyrusChatMcp
  # Signals that the coding-mode agent has finished implementing and is ready
  # for Syrus to take over grading and PR opening.
  #
  # Steps performed:
  #   1. Verify the calling chat session owns the Job's coding lock.
  #   2. Commit any uncommitted changes in the coding workspace.
  #   3. Push the branch to origin.
  #   4. Transition the Job from :coding → :implemented (keeping linked_chat_id
  #      so grader results can route back to this session).
  #   5. Cancel held initial workflows (their implement step is no longer needed).
  #   6. Create and start a coding_handoff workflow (graders → summarize → pr_open).
  #
  # Gated by the coding_mode feature flag.
  class CompleteImplementStepTool < MCP::Tool
    extend JobLifecycleToolSupport

    tool_name "complete_implement_step"

    description <<~DESC
      Signal that implementation is complete and hand off to Syrus for grading
      and PR opening. Commits any uncommitted changes from the coding session,
      pushes the branch, then triggers the grader workflow. Only callable when
      the chat session owns the Job's Coding Mode lock.
    DESC

    input_schema(
      properties: {
        job_id: {
          type: "integer",
          description: "ID of the Job whose coding session is complete."
        },
        commit_message: {
          type: "string",
          description: "Optional commit message for any uncommitted changes. Defaults to 'Coding session: finish implementation'."
        }
      },
      required: %w[job_id]
    )

    class << self
      def call(job_id:, server_context:, commit_message: nil)
        return SyrusChatMcp.invalid("Coding Mode is not enabled") unless Feature.coding_mode_enabled?

        chat_session = server_context.fetch(:chat_session)
        job, error = find_repository_job(chat_session, job_id)
        return error if error

        unless job.coding?
          return SyrusChatMcp.invalid(
            "job #{job_id} is not in coding state (current: #{job.state})"
          )
        end

        unless job.linked_chat_id == chat_session.id
          return SyrusChatMcp.invalid(
            "this chat session does not own job #{job_id}"
          )
        end

        workspace_path = ChatWorkspace.repo_path_for(chat_session, job.repository)
        unless workspace_path.directory?
          return SyrusChatMcp.invalid(
            "coding workspace not found for job #{job_id} — was the coding session initialized?"
          )
        end

        commit_and_push!(job, workspace_path, commit_message: commit_message)

        job.complete_coding_handoff!

        workflow = Workflows::CodingHandoff.instantiate(
          job: job,
          agent_provider: job.agent_provider
        )
        StepDispatcher.start_workflow(workflow)

        SyrusChatMcp.success(
          message: "Done — handed off to Syrus for grading. Results will appear here.",
          job_id: job.id,
          job_state: job.reload.state,
          workflow_id: workflow.id
        )
      rescue GitRunner::GitError => e
        Rails.logger.error("[SyrusChatMcp::CompleteImplementStepTool] git error: #{e.message}")
        SyrusChatMcp.tool_error("Git operation failed: #{e.message}")
      rescue ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
      rescue StandardError => e
        Rails.logger.error("[SyrusChatMcp::CompleteImplementStepTool] #{e.class}: #{e.message}")
        SyrusChatMcp.tool_error("Handoff failed: #{e.message}")
      end

      private

      def commit_and_push!(job, workspace_path, commit_message: nil)
        git = GitRunner.new(env: { "GIT_TERMINAL_PROMPT" => "0" })
        path = workspace_path.to_s

        status = git.run("status", "--porcelain", chdir: path)
        if status.strip.present?
          git.run("add", "-A", chdir: path)
          message = commit_message.presence || "Coding session: finish implementation"
          git.run("commit", "-m", message, chdir: path)
        end

        token = GithubClient.for(repository: job.repository, user: job.user).access_token
        authenticated_url = job.repository.authenticated_push_url(token)
        git.run("push", authenticated_url, "HEAD:#{job.branch_name}", chdir: path)
      end
    end
  end
end
